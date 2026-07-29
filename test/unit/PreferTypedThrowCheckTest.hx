package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferTypedThrow;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-typed-throw` check: `throw '<string>'` is flagged `Info` and — when the
 * catch-clause gate passes — boxed into `throw new Exception('<string>')` with the exception
 * reference spelled by `TypeRefPrinter`. Covers fix mode, the degraded report-only mode a
 * `String` / `Dynamic` / `Any` catch anywhere in scope forces, the short-name collision
 * fallback to the qualified path, and the import insertion position.
 */
class PreferTypedThrowCheckTest extends Test {

	// --- what is flagged ---

	public function testStringThrowFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-typed-throw', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSpanIsTheLiteral(): Void {
		final src: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('\'boom\'', src.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testInterpolatedStringThrowFlagged(): Void {
		// Double-quoted fixture source: the `$id` inside it is fixture text, not interpolation.
		Assert.equals(1, violations("class C {\n\n\tpublic function f():Void {\n\t\tthrow 'bad $id';\n\t}\n\n}\n").length);
	}

	public function testDoubleQuotedStringThrowFlagged(): Void {
		Assert.equals(1, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow "boom";\n\t}\n\n}\n').length);
	}

	public function testParenthesisedLiteralFlagged(): Void {
		Assert.equals(1, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow (\'boom\');\n\t}\n\n}\n').length);
	}

	public function testConstructedThrowNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow new E(\'boom\');\n\t}\n\n}\n').length);
	}

	public function testExpressionThrowNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow err;\n\t}\n\n}\n').length);
	}

	// --- fix mode ---

	public function testFixBoxesAndAddsImport(): Void {
		final out: String = applyFix('class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n');
		Assert.isTrue(out.indexOf('throw new Exception(\'boom\');') != -1, 'literal boxed, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') != -1, 'import added, got: $out');
	}

	public function testFixKeepsInterpolatedLiteralVerbatim(): Void {
		final out: String = applyFix("class C {\n\n\tpublic function f():Void {\n\t\tthrow 'bad $id';\n\t}\n\n}\n");
		Assert.isTrue(out.indexOf("throw new Exception('bad $id');") != -1, 'interpolation carried through, got: $out');
	}

	public function testFixUsesExistingImportWithoutAddingASecond(): Void {
		final src: String = 'import haxe.Exception;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new Exception(\'boom\');') != -1, 'literal boxed, got: $out');
		Assert.equals(1, occurrences(out, 'import haxe.Exception;'));
	}

	// --- degraded report-only mode ---

	public function testStringCatchInScopeDegradesToReportOnly(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e:String) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
		Assert.equals(0, check.fix(thrower, vs, new HaxeQueryPlugin()).length, 'a degraded finding yields no edit');
	}

	public function testDynamicCatchInScopeDegradesToReportOnly(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e : Dynamic) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
	}

	public function testValueExceptionCatchInScopeDegradesToReportOnly(): Void {
		// `haxe.ValueException` is the wrapper the RUNTIME builds for a raw throw — it matches
		// `throw 'boom'` and does NOT match `throw new Exception('boom')`, exactly like a String
		// catch. Verified against the compiler before the name joined the gate.
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e:haxe.ValueException) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
		Assert.equals(0, check.fix(thrower, vs, new HaxeQueryPlugin()).length);
	}

	public function testLineBrokenCatchParameterDegrades(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (\n\t\t\te:String\n\t\t) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
	}

	public function testThrowInExpressionPositionFlaggedAndFixed(): Void {
		// `ThrowExpr` is a distinct grammar kind from `ThrowStmt` — both must be reached.
		final src: String = 'class C {\n\n\tpublic function f(c:Bool):Int {\n\t\treturn c ? 1 : throw \'nope\';\n\t}\n\n}\n';
		Assert.equals(1, violations(src).length);
		Assert.isTrue(applyFix(src).indexOf('throw new Exception(\'nope\')') != -1);
	}

	public function testTwoThrowsShareOneImport(): Void {
		final src: String =
			'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'a\';\n\t}\n\n\tpublic function g():Void {\n\t\tthrow \'b\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new Exception(\'a\');') != -1, 'first boxed, got: $out');
		Assert.isTrue(out.indexOf('throw new Exception(\'b\');') != -1, 'second boxed, got: $out');
		Assert.equals(1, occurrences(out, 'import haxe.Exception;'));
	}

	public function testSameFileCatchAllDegrades(): Void {
		final src: String = 'class C {\n\n\tpublic function f():Void {\n\t\ttry g() catch (e:Any) {}\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testTypedCatchDoesNotDegrade(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e:Exception) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') == -1, 'not degraded, got: ${vs[0].message}');
		Assert.isTrue(check.fix(thrower, vs, new HaxeQueryPlugin()).length > 0, 'a non-degraded finding yields edits');
	}

	public function testUntypedCatchDoesNotDegrade(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.isTrue(vs[0].message.indexOf('report-only') == -1, 'not degraded, got: ${vs[0].message}');
	}

	// --- collision mode ---

	public function testCollidingExceptionNameUsesQualifiedPath(): Void {
		final src: String =
			'package pkg;\n\nimport pkg.err.Exception;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new haxe.Exception(\'boom\');') != -1, 'qualified on collision, got: $out');
		Assert.equals(0, occurrences(out, 'import haxe.Exception;'));
	}

	public function testLocalExceptionTypeUsesQualifiedPath(): Void {
		final src: String =
			'package pkg;\n\nclass Exception {}\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new haxe.Exception(\'boom\');') != -1, 'qualified on a module-local type, got: $out');
	}

	public function testConditionalRegionQualifiedWithNoImport(): Void {
		final src: String = 'class C {\n\n\tpublic function f():Void {\n\t\t#if debug\n\t\tthrow \'boom\';\n\t\t#end\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new haxe.Exception(\'boom\');') != -1, 'qualified inside #if, got: $out');
		Assert.equals(0, occurrences(out, 'import haxe.Exception;'));
	}

	// --- import insertion position ---

	public function testImportKeepsASortedImportBlockSorted(): Void {
		final src: String =
			'package pkg;\n\nimport a.Alpha;\nimport z.Zeta;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(
			out.indexOf('import a.Alpha;\nimport haxe.Exception;\nimport z.Zeta;') != -1, 'import lands in sorted position, got: $out'
		);
	}

	public function testImportAppendsAfterAnUnsortedBlock(): Void {
		final src: String =
			'package pkg;\n\nimport z.Zeta;\nimport a.Alpha;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('import a.Alpha;\nimport haxe.Exception;') != -1, 'import appended after the block, got: $out');
	}

	// --- registration ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-typed-throw'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-typed-throw'));
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new PreferTypedThrow() is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { throw').length);
	}

	// --- helpers -------------------------------------------------------------------

	private function violations(src: String): Array<Violation> {
		return new PreferTypedThrow().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: PreferTypedThrow = new PreferTypedThrow();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function occurrences(haystack: String, needle: String): Int {
		var count: Int = 0;
		var i: Int = haystack.indexOf(needle);
		while (i >= 0) {
			count++;
			i = haystack.indexOf(needle, i + needle.length);
		}
		return count;
	}

}
