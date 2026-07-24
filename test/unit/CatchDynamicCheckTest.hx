package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CatchDynamic;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.check.LintConfig;

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
		// `trace(e)` is a pure logging use (a bare trace argument) — report-only BY DEFAULT because
		// arm (b) (`fixLoggingUses`) is off; with the option on the swap is applied.
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
		// `Std.string(e)` is a pure logging use — report-only BY DEFAULT; arm (b) (`fixLoggingUses`) is the
		// project's opt-in to swap it, safe via the ValueException logged-text equivalence.
		final src: String = 'class C { public function f():Void { try g() catch (e:Dynamic) { Std.string(e); } } }';
		Assert.equals(0, editCount(src));
	}


	private function applyFixLogging(src: String): String {
		final check: CatchDynamic = new CatchDynamic();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules": {"catch-dynamic": {"fixLoggingUses": true}}}'));
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function editCountLogging(src: String): Int {
		final check: CatchDynamic = new CatchDynamic();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules": {"catch-dynamic": {"fixLoggingUses": true}}}'));
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length;
	}

	public function testFixLoggingInterpolationRenamesAndImports(): Void {
		// Arm (b), opt-in `fixLoggingUses`: the caught value is used ONLY as a logging value
		// (string interpolation `$msg`). The swap renames the var to `exception`, rewrites
		// `$msg` -> `$exception`, and adds the import — the shipped hand-conversion style.
		// Double-quoted fixture keeps `$msg` literal in the source under test.
		final out: String = applyFixLogging(
			"class C { public function f():Void { try g() catch (msg:Dynamic) { trace('error creating SystemData : $msg'); } } }"
		);
		final expected: String = "import haxe.Exception;\nclass C { public function f():Void { try g() catch (exception:Exception) { trace('error creating SystemData : $exception'); } } }";
		Assert.equals(expected, out);
	}

	public function testFixLoggingTraceTrailingArgRenamed(): Void {
		// The caught value is passed as a bare trace() argument — renamed to `exception`.
		final out: String = applyFixLogging("class C { public function f():Void { try g() catch (e:Dynamic) { trace('boom', e); } } }");
		final expected: String = "import haxe.Exception;\nclass C { public function f():Void { try g() catch (exception:Exception) { trace('boom', exception); } } }";
		Assert.equals(expected, out);
	}

	public function testFixLoggingNestedInnerCatchUntouched(): Void {
		// The outer catch-all uses its value only for logging; a nested inner catch (Exception)
		// is not a catch-all and must be left byte-for-byte untouched.
		final out: String = applyFixLogging(
			"class C { public function f():Void { try a() catch (msg:Dynamic) { trace('err: $msg'); try b() catch (e:Exception) { recover(); } } } }"
		);
		final expected: String = "import haxe.Exception;\nclass C { public function f():Void { try a() catch (exception:Exception) { trace('err: $exception'); try b() catch (e:Exception) { recover(); } } } }";
		Assert.equals(expected, out);
	}

	public function testFixLoggingStdStringRenamed(): Void {
		// `Std.string(e)` is a pure stringify — with the option ON the arg is renamed and the type swapped.
		final out: String = applyFixLogging('class C { public function f():Void { try g() catch (e:Dynamic) { Std.string(e); } } }');
		Assert.isTrue(out.indexOf('(exception:Exception)') != -1, 'type swapped, got: $out');
		Assert.isTrue(out.indexOf('Std.string(exception)') != -1, 'arg renamed, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') != -1, 'import added, got: $out');
	}

	public function testFixLoggingBracedInterpolationRenamed(): Void {
		// Braced `${e}` interpolation is the same pure-stringify use as bare `$e`.
		final out: String = applyFixLogging("class C { public function f():Void { try g() catch (e:Dynamic) { trace('x ${e}'); } } }");
		Assert.isTrue(out.indexOf('(exception:Exception)') != -1, 'type swapped, got: $out');
		Assert.isTrue(out.indexOf("${exception}") != -1, 'braced interpolation renamed, got: $out');
	}

	public function testFixLoggingConditionalQualifiedNoImport(): Void {
		// A logging-use catch inside `#if … #end` swaps to fully-qualified `haxe.Exception` and adds
		// no import — mirroring arm (a)'s conditional convention.
		final out: String = applyFixLogging(
			"class C {\n\tpublic function f():Void {\n\t\t#if debug\n\t\ttry g() catch (e:Dynamic) { trace('x $e'); }\n\t\t#end\n\t}\n}"
		);
		Assert.isTrue(out.indexOf('(exception:haxe.Exception)') != -1, 'conditional swap qualified, got: $out');
		Assert.isTrue(out.indexOf("$exception") != -1, 'interpolation renamed, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') == -1, 'no import for a conditional-only swap, got: $out');
	}

	public function testFixLoggingFieldAccessStaysFinding(): Void {
		// `e.message` reads the raw-value API, not a pure stringify — even with the option ON the
		// finding stays (no edit).
		final src: String = 'class C { public function f():Void { try g() catch (e:Dynamic) { log(e.message); } } }';
		Assert.equals(0, editCountLogging(src));
	}

	public function testFixLoggingThrowStaysFinding(): Void {
		// A logging use PLUS a propagation (`throw e`) is not all-logging — the finding stays.
		final src: String = "class C { public function f():Void { try g() catch (e:Dynamic) { trace('x $e'); throw e; } } }";
		Assert.equals(0, editCountLogging(src));
	}

	public function testFixLoggingRenameCollisionStaysFinding(): Void {
		// Renaming to `exception` would capture an existing `exception` referenced in the body —
		// the rewrite is skipped to avoid shadowing it.
		final src: String = "class C { public function f():Void { var exception = 1; try g() catch (e:Dynamic) { trace('x $e'); use(exception); } } }";
		Assert.equals(0, editCountLogging(src));
	}

	public function testFixLoggingDefaultOffKeepsFinding(): Void {
		// `fixLoggingUses` is OFF by default — the logging-use catch stays a report-only finding.
		final src: String = "class C { public function f():Void { try g() catch (msg:Dynamic) { trace('err: $msg'); } } }";
		Assert.equals(0, editCount(src));
	}

	public function testFixLoggingOptionOnUnusedStillArmA(): Void {
		// The option only unlocks the logging-use arm; an UNUSED catch still takes arm (a),
		// which keeps the original var name.
		final out: String = applyFixLogging('class C { public function f():Void { try g() catch (e:Dynamic) {} } }');
		Assert.isTrue(out.indexOf('(e:Exception)') != -1, 'arm-a keeps the var name, got: $out');
	}

}
