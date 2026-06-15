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
 * points) exceeds the default threshold (10) is flagged `Warning`; a simpler
 * one is not. Boundary is pinned with `&&` chains (each `&&` is one point); the
 * mixed-construct, nested-function, and lambda-folding behaviors are covered
 * too. Report-only — `fix` yields no edits.
 */
class ComplexityCheckTest extends Test {

	public function testSimpleFunctionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int { return 1; }\n}').length);
	}

	public function testOverThresholdFlagged(): Void {
		// 10 `&&` -> 10 decision points -> score 11 > 10.
		final vs: Array<Violation> =
			violations('class C {\n\tfunction big(a:Bool):Bool {\n\t\treturn a && a && a && a && a && a && a && a && a && a && a;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('complexity', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'big'"));
		Assert.isTrue(vs[0].message.contains('11'));
	}

	public function testThresholdBoundaryNotFlagged(): Void {
		// 9 `&&` -> score 10, which is NOT > 10.
		Assert.equals(
			0,
			violations('class C {\n\tfunction edge(a:Bool):Bool {\n\t\treturn a && a && a && a && a && a && a && a && a && a;\n\t}\n}').length
		);
	}

	public function testMixedConstructsCounted(): Void {
		// if/while/for/case/catch/ternary/?? all contribute — well over the threshold.
		final src: String = 'class C {\n' + '\tfunction mixed(a:Int):Int {\n' + '\t\tif (a > 0) return 1;\n' + '\t\tif (a > 1) return 2;\n'
			+ '\t\twhile (a > 2) a--;\n' + '\t\tfor (i in 0...a) trace(i);\n'
			+ '\t\tswitch a { case 1: trace(1); case 2: trace(2); case 3: trace(3); case _: trace(0); }\n'
			+ '\t\ttry { throw "x"; } catch (e:String) {} catch (e:Int) {}\n' + '\t\tfinal t = a > 0 ? 1 : 2;\n'
			+ '\t\tfinal n = (null : Null<Int>) ?? 0;\n' + '\t\tfinal b = a > 0 && a < 10;\n' + '\t\treturn b ? t + n : 0;\n' + '\t}\n'
			+ '}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'mixed'"));
	}

	public function testNestedFunctionMeasuredSeparately(): Void {
		// `inner` (10 &&) is flagged on its own; `outer`'s branches exclude it.
		final vs: Array<Violation> =
			violations(
				'class C {\n\tfunction outer():Void {\n\t\tfunction inner(a:Bool):Bool {\n\t\t\treturn a && a && a && a && a && a && a && a && a && a && a;\n\t\t}\n\t\tinner(true);\n\t}\n}'
			);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'inner'"));
	}

	public function testLambdaFoldsIntoEnclosing(): Void {
		// The lambda's 10 `&&` count toward `withLambda` (lambdas are not function units).
		final vs: Array<Violation> =
			violations(
				'class C {\n\tfunction withLambda():Bool {\n\t\tfinal g = (a:Bool) -> a && a && a && a && a && a && a && a && a && a && a;\n\t\treturn g(true);\n\t}\n}'
			);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'withLambda'"));
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction big(a:Bool):Bool {\n\t\treturn a && a && a && a && a && a && a && a && a && a && a;\n\t}\n}';
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
		// the threshold so a function the default (10) ignores is flagged.
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

}
