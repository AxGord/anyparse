package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Complexity;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

import anyparse.grammar.haxe.CheckstyleConfigLoader;

/**
 * The `complexity` check: a function whose cyclomatic complexity (1 + decision
 * points) exceeds the default threshold (20) is flagged `Warning`; a simpler
 * one is not. Boundary is pinned with `&&` chains (each `&&` is one point); the
 * mixed-construct, nested-function, and lambda-folding behaviors are covered
 * too. Report-only — `fix` yields no edits.
 */
class ComplexityCheckTest extends Test {

	public function testSimpleFunctionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int { return 1; }\n}').length);
	}

	public function testOverThresholdFlagged(): Void {
		// 20 `&&` -> 20 decision points -> score 21 > 20.
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction big(a:Bool):Bool {\n\t\treturn a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a;\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('complexity', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'big'"));
		Assert.isTrue(vs[0].message.contains('21'));
	}

	public function testThresholdBoundaryNotFlagged(): Void {
		// 19 `&&` -> score 20, which is NOT > 20.
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction edge(a:Bool):Bool {\n\t\treturn a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a;\n\t}\n}'
			).length
		);
	}

	public function testMixedConstructsCounted(): Void {
		// if/while/for/switch/catch/ternary/?? plus a long && chain — over the threshold
		// (score 21: the switch counts once now, not once per case).
		final src: String = 'class C {\n\tfunction mixed(a:Int):Int {\n\t\tif (a > 0) return 1;\n\t\tif (a > 1) return 2;\n'
			+ '\t\twhile (a > 2) a--;\n' + '\t\tfor (i in 0...a) trace(i);\n'
			+ '\t\tswitch a { case 1: trace(1); case 2: trace(2); case 3: trace(3); case _: trace(0); }\n'
			+ '\t\ttry { throw "x"; } catch (e:String) {} catch (e:Int) {}\n' + '\t\tfinal t = a > 0 ? 1 : 2;\n'
			+ '\t\tfinal n = (null : Null<Int>) ?? 0;\n'
			+ '\t\tfinal b = a < 0 && a < 1 && a < 2 && a < 3 && a < 4 && a < 5 && a < 6 && a < 7 && a < 8 && a < 9 && a < 10;\n'
			+ '\t\treturn b ? t + n : 0;\n' + '\t}\n' + '}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'mixed'"));
	}

	public function testNestedFunctionFoldsIntoEnclosing(): Void {
		// A local function is NOT a separate unit: `inner`'s 20 `&&` count toward
		// `outer` (score 21), so a block cannot be hidden from the metric by being
		// wrapped in a local function. `inner` is not reported on its own.
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction outer():Void {\n\t\tfunction inner(a:Bool):Bool {\n\t\t\treturn a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a;\n\t\t}\n\t\tinner(true);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'outer'"));
	}

	public function testLambdaFoldsIntoEnclosing(): Void {
		// The lambda's 20 `&&` count toward `withLambda` (lambdas are not function units).
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction withLambda():Bool {\n\t\tfinal g = (a:Bool) -> a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a;\n\t\treturn g(true);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'withLambda'"));
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction big(a:Bool):Bool {\n\t\treturn a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a && a;\n\t}\n}';
		final check: Complexity = new Complexity();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('complexity'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('complexity'));
	}

	private function violations(src: String): Array<Violation> {
		return new Complexity().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	public function testCheckstyleMaxFromThresholds(): Void {
		// Lowest configured onset (20) minus one — checkstyle flags `>=`, this check `>`.
		Assert.equals(
			19,
			CheckstyleConfigLoader.loadComplexityMax(
				'{"checks":[{"type":"CyclomaticComplexity","props":{"thresholds":[{"severity":"WARNING","complexity":20},{"severity":"ERROR","complexity":25}]}}]}'
			)
		);
	}

	public function testCheckstyleMaxLowThreshold(): Void {
		Assert.equals(
			5,
			CheckstyleConfigLoader.loadComplexityMax(
				'{"checks":[{"type":"CyclomaticComplexity","props":{"thresholds":[{"severity":"WARNING","complexity":6}]}}]}'
			)
		);
	}

	public function testCheckstyleMaxDefaultWhenNoThresholds(): Void {
		// A configured check with no explicit thresholds uses checkstyle's default onset 20.
		Assert.equals(19, CheckstyleConfigLoader.loadComplexityMax('{"checks":[{"type":"CyclomaticComplexity","props":{}}]}'));
	}

	public function testCheckstyleMaxNullWhenCheckAbsent(): Void {
		Assert.isNull(CheckstyleConfigLoader.loadComplexityMax('{"checks":[{"type":"Indentation","props":{}}]}'));
	}

	public function testCheckstyleMaxIgnoresIgnoreSeverity(): Void {
		// An IGNORE-severity threshold never flags, so the WARNING onset (8) wins -> 7.
		Assert.equals(
			7,
			CheckstyleConfigLoader.loadComplexityMax(
				'{"checks":[{"type":"CyclomaticComplexity","props":{"thresholds":[{"severity":"IGNORE","complexity":3},{"severity":"WARNING","complexity":8}]}}]}'
			)
		);
	}

	public function testRespectsCheckstyleThresholdFromDisk(): Void {
		// End-to-end: a checkstyle.json discovered by walking up from the file lowers
		// the threshold so a function the default (20) ignores is flagged.
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? tmp : '/tmp';
		final dir: String = '$base/anyparse_cx_cfg_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent(
			'$dir/checkstyle.json',
			'{"checks":[{"type":"CyclomaticComplexity","props":{"thresholds":[{"severity":"WARNING","complexity":3}]}}]}'
		);
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tfunction f(a:Bool):Bool { return a && a && a; }\n}';
		sys.io.File.saveContent(path, src);
		final vs: Array<Violation> = new Complexity().run([{ file: path, source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('max 2'));
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile('$dir/checkstyle.json');
		sys.FileSystem.deleteDirectory(dir);
	}

	public function testDispatcherSwitchNotInflated(): Void {
		// A flat 30-way dispatcher — each case a single call — is ONE decision (which
		// arm is taken), not 30. Under the old per-case count it scored 31 and flagged;
		// the cognitive-switch count scores it 2, so a command dispatcher is not a false hotspot.
		final arms: String = [for (i in 0...30) '\t\t\tcase $i: run$i();'].join('\n');
		final src: String = 'class C {\n\tfunction dispatch(x:Int):Void {\n\t\tswitch x {\n' + arms
			+ '\n\t\t\tcase _: none();\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testSwitchBodyBranchesStillCount(): Void {
		// The switch is +1, but branches INSIDE a case body still count via recursion — a
		// switch whose arm carries a 20-`&&` chain scores 22 and stays flagged, so the
		// exemption removes only case-count inflation, never real branching.
		final chain: String = [for (_ in 0...21) 'a'].join(' && ');
		final src: String = 'class C {\n\tfunction f(a:Bool):Bool {\n\t\tswitch a {\n\t\t\tcase true: return ' + chain
			+ ';\n\t\t\tcase _: return false;\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'f'"));
	}

	public function testConditionalGuardedSwitchCountedOnce(): Void {
		// Regression: a switch with an `#if`-guarded case run wraps those cases in a
		// conditional node that ALSO holds `CaseBranch` children. The switch is identified
		// by KIND, not by "has a case child", so that wrapper is NOT counted as a second
		// switch. 18 `&&` + this switch scores exactly 20 (not flagged); the old wrapper
		// double-count would have tipped it to 21 (flagged).
		final chain: String = [for (_ in 0...19) 'a'].join(' && ');
		final src: String = 'class C {\n\tfunction f(a:Bool, x:Int):Void {\n\t\tfinal b = ' + chain
			+ ';\n\t\tswitch x {\n\t\t\t#if debug\n\t\t\tcase 1: p();\n\t\t\tcase 4: r();\n\t\t\t#end\n\t\t\tcase 2: q();\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

}
