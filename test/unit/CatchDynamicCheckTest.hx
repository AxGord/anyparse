package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CatchDynamic;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `catch-dynamic` check: a `catch` clause whose declared exception type is
 * `Dynamic` (or `Any`) is flagged `Warning` (prefer `catch (exception:Exception)`).
 * A typed catch of any other name (`Exception`, a custom class, `String`) and an
 * untyped `catch (e)` are not flagged. `fix` swaps an UNUSED catch-all to `Exception` (adding the import); a used one stays a finding.
 */
class CatchDynamicCheckTest extends Test {

	public function testDynamicFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Dynamic) {}\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('catch-dynamic', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('catch type \'Dynamic\' is a raw catch-all — prefer catch (exception:Exception)', vs[0].message);
	}

	public function testDynamicSpanIsParameterRegion(): Void {
		final src: String = 'class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Dynamic) {}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('(e:Dynamic)', src.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testAnyFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Any) {}\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('catch type \'Any\' is a raw catch-all — prefer catch (exception:Exception)', vs[0].message);
	}

	public function testExceptionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Exception) {}\n\t}\n}').length);
	}

	public function testCustomTypeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:MyError) {}\n\t}\n}').length);
	}

	public function testStringNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:String) {}\n\t}\n}').length);
	}

	public function testUntypedCatchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e) {}\n\t}\n}').length);
	}

	public function testMixedCatchesFlagsOnlyDynamic(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Dynamic) {} catch (x:Exception) {}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('catch type \'Dynamic\' is a raw catch-all — prefer catch (exception:Exception)', vs[0].message);
	}

	public function testFixSwapsUnusedToExceptionAndImports(): Void {
		final out: String = applyFix('class C { public function f():Void { try g() catch (e:Dynamic) {} } }');
		Assert.isTrue(out.indexOf('(e:Exception)') != -1, 'type should become Exception, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') != -1, 'import should be added, got: $out');
		Assert.isTrue(out.indexOf('Dynamic') == -1, 'Dynamic should be gone, got: $out');
	}

	public function testFixKeepsUsedCatchAsFinding(): Void {
		// The body reads `e` — its raw-value API differs from the Exception wrapper, so the
		// swap is not zero-behaviour-change; the finding stays, fix yields no edits.
		final src: String = 'class C { public function f():Void { try g() catch (e:Dynamic) { trace(e); } } }';
		Assert.equals(0, editCount(src));
	}

	public function testFixKeepsInterpolationUseAsFinding(): Void {
		// `e` referenced inside string interpolation counts as used (parses to an interpolation
		// ident), so the catch is left untouched. Double-quoted fixture keeps `$e` literal here.
		final src: String = "class C { public function f():Void { try g() catch (e:Dynamic) { trace('boom $e'); } } }";
		Assert.equals(0, editCount(src));
	}

	public function testFixUsesQualifiedNameOnCollision(): Void {
		// A same-file type named `Exception` would shadow a bare `Exception`, so the swap uses
		// fully-qualified `haxe.Exception` and adds no import.
		final out: String = applyFix('class Exception {} class C { public function f():Void { try g() catch (e:Dynamic) {} } }');
		Assert.isTrue(out.indexOf('(e:haxe.Exception)') != -1, 'should use qualified name, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') == -1, 'no import on collision, got: $out');
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('catch-dynamic'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('catch-dynamic'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { try {').length);
	}

	public function testSpacedDynamicFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e : Dynamic) {}\n\t}\n}').length);
	}

	public function testArrayOfDynamicNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Array<Dynamic>) {}\n\t}\n}').length);
	}

	public function testFunctionTypeCatchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Int->Void) {}\n\t}\n}').length);
	}

	public function testFixNoDuplicateImportWhenAlreadyImported(): Void {
		final out: String = applyFix('import haxe.Exception;\nclass C { public function f():Void { try g() catch (e:Dynamic) {} } }');
		Assert.isTrue(out.indexOf('(e:Exception)') != -1, 'should use the already-imported short name, got: $out');
		Assert.equals(
			-1, out.indexOf('import haxe.Exception;', out.indexOf('import haxe.Exception;') + 1), 'no duplicate import, got: $out'
		);
	}

	public function testFixUsingCollisionUsesQualified(): Void {
		// `using foo.Exception;` binds the simple name `Exception`, so the swap must qualify.
		final out: String = applyFix('using foo.Exception;\nclass C { public function f():Void { try g() catch (e:Dynamic) {} } }');
		Assert.isTrue(out.indexOf('(e:haxe.Exception)') != -1, 'using-bound Exception should force qualified name, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') == -1, 'no import on collision, got: $out');
	}

	private function editCount(src: String): Int {
		final check: CatchDynamic = new CatchDynamic();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length;
	}


	private function applyFix(src: String): String {
		final check: CatchDynamic = new CatchDynamic();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function violations(src: String): Array<Violation> {
		return new CatchDynamic().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}


	public function testFixInsideConditionalUsesQualifiedNoImport(): Void {
		// An unused catch-all inside `#if … #end` must swap to fully-qualified `haxe.Exception`
		// with NO added import — a top-level `import haxe.Exception;` would be unused in builds
		// where the conditional block is compiled out (the project's #if-Exception convention).
		final out: String = applyFix(
			'class C {\n\tpublic function f():Void {\n\t\t#if debug\n\t\ttry g() catch (e:Dynamic) {}\n\t\t#end\n\t}\n}'
		);
		Assert.isTrue(out.indexOf('(e:haxe.Exception)') != -1, 'conditional swap should use qualified name, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') == -1, 'no import for a conditional-only swap, got: $out');
		Assert.isTrue(out.indexOf('Dynamic') == -1, 'Dynamic should be gone, got: $out');
	}


	public function testFixMixedConditionalAndPlainCatches(): Void {
		// A plain unused catch takes the short `Exception` + import; a sibling inside `#if`
		// takes qualified `haxe.Exception`. The import is added once, driven by the plain swap.
		final src: String = 'class C {\n\tpublic function f():Void {\n\t\ttry a() catch (e:Dynamic) {}\n\t\t#if debug\n\t\ttry b() catch (e:Dynamic) {}\n\t\t#end\n\t}\n}';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('(e:haxe.Exception)') != -1, 'conditional swap should be qualified, got: $out');
		Assert.isTrue(out.indexOf('(e:Exception)') != -1, 'plain swap should use the short name, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') != -1, 'plain swap should add the import once, got: $out');
	}


	public function testFixKeepsStdStringUseAsFinding(): Void {
		// Arm (b), deliberately report-only: a body that stringifies the caught value
		// (`Std.string(e)`, interpolation, a trace/log argument) is NOT provably equivalent —
		// the swap rebinds `e` from the raw thrown value to a ValueException wrapper. It is
		// left a finding for a manual decision (accept the wrapper, or migrate to `.unwrap()`).
		final src: String = 'class C { public function f():Void { try g() catch (e:Dynamic) { Std.string(e); } } }';
		Assert.equals(0, editCount(src));
	}

}
