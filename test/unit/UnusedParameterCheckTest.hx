package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedParameter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.check.LintConfig;

/**
 * The `unused-parameter` check: a function parameter never referenced in its
 * body is flagged. Used parameters, `_`-prefixed parameters, body-less
 * (interface / abstract) method declarations, methods of a type carrying a
 * supertype clause (`extends` / `implements`, a contract candidate), and
 * functions captured as a VALUE (passed as an argument, assigned, returned —
 * their signature is fixed from outside) are not flagged. A named local
 * function or a confined private method whose call set is provably complete
 * within the file is `Warning`, and `fix` removes the parameter plus its
 * in-file call arguments. Every other flagged parameter (a public / unconfined
 * method) stays `Info` and is report-only by default; a project that opts into
 * `renameSilence` also gets the `_<name>` silence-rename, unless a `_<name>`
 * collision blocks it.
 */
class UnusedParameterCheckTest extends Test {

	public function testUnusedParameterFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('unused-parameter', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('unused parameter \'value\'', vs[0].message);
	}

	public function testUsedParameterNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(value:Int):Void {\n\t\tg(value);\n\t}\n}').length);
	}

	public function testUnderscorePrefixNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(_value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testImplementsContractNotFlagged(): Void {
		Assert.equals(0, violations('class C implements I {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testExtendsContractNotFlagged(): Void {
		Assert.equals(0, violations('class C extends B {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testInterfaceMethodNotFlagged(): Void {
		Assert.equals(0, violations('interface I {\n\tfunction f(value:Int):Void;\n}').length);
	}

	public function testLocalFunctionParameterFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function m():Void {\n\t\tfunction inner(value:Int):Void {\n\t\t\tg();\n\t\t}\n\t\tinner(1);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('unused parameter \'value\'', vs[0].message);
		// A named local function called directly is the autofixable subset.
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testParameterUsedInSiblingDefaultNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(a:Int, b:Int = a):Void {\n\t\tg(b);\n\t}\n}').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unused-parameter'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unused-parameter'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(').length);
	}

	public function testLocalFunctionParameterAutofixed(): Void {
		final src: String =
			'class C {\n\tpublic function m():Void {\n\t\tfunction inner(value:Int):Void {\n\t\t\tg();\n\t\t}\n\t\tinner(1);\n\t}\n}';
		Assert.equals(
			'class C {\n\tpublic function m():Void {\n\t\tfunction inner():Void {\n\t\t\tg();\n\t\t}\n\t\tinner();\n\t}\n}', applyFix(src)
		);
	}

	public function testConfinedPrivateMethodParameterAutofixed(): Void {
		final src: String =
			'class C {\n\tprivate function h(a:Int, b:Int):Int {\n\t\treturn a;\n\t}\n\n\tfunction u():Int {\n\t\treturn h(1, 2);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(
			'class C {\n\tprivate function h(a:Int):Int {\n\t\treturn a;\n\t}\n\n\tfunction u():Int {\n\t\treturn h(1);\n\t}\n}',
			applyFix(src)
		);
	}

	public function testPublicMethodParameterRenamed(): Void {
		// A public method's callers may live in other files, so removal cannot be
		// proven safe — the finding stays `Info`, and with `renameSilence` opted in
		// `fix` renames the parameter to `_<name>` (a decl-site-only, cross-file-safe
		// silencing) instead of removing it.
		final src: String = 'class C {\n\tpublic function f(x:Int, unused:Int):Int {\n\t\treturn x;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('class C {\n\tpublic function f(x:Int, _unused:Int):Int {\n\t\treturn x;\n\t}\n}', applyFix(src, true));
	}

	public function testRenameSilenceOffProducesNoEdits(): Void {
		// The default: the `Info` finding is still reported, but `fix` offers NO edit —
		// the silence-rename is opt-in via `renameSilence`.
		final src: String = 'class C {\n\tpublic function f(x:Int, unused:Int):Int {\n\t\treturn x;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(src, applyFix(src));
	}

	public function testLocalFunctionPassedByValueNotFlagged(): Void {
		// `inner` is captured as a value (passed to `take`), so whatever consumes the
		// reference fixes its signature — the ignored parameter is mandated, not dead,
		// so nothing is reported and nothing is fixed.
		final src: String =
			'class C {\n\tpublic function m():Void {\n\t\tfunction inner(value:Int):Void {\n\t\t\tg();\n\t\t}\n\t\ttake(inner);\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src, true));
	}

	public function testMethodPassedAsCallbackNotFlagged(): Void {
		// The `addEventListener` shape: a private method registered as a listener. Its
		// signature is fixed by the dispatcher, so an unread parameter is not actionable.
		final src: String =
			'class C {\n\tpublic function m():Void {\n\t\taddEventListener(E, onFoo);\n\t}\n\n\tprivate function onFoo(event:Int):Void {\n\t\tg();\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testMethodCapturedViaThisNotFlagged(): Void {
		// `this.cb` assigned to a local is the same capture through a field access.
		final src: String =
			'class C {\n\tpublic function m():Void {\n\t\tvar f = this.cb;\n\t}\n\n\tpublic function cb(value:Int):Void {\n\t\tg();\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testMethodReturnedAsValueNotFlagged(): Void {
		// Returning the method hands its signature to the caller.
		final src: String =
			'class C {\n\tpublic function m():Dynamic {\n\t\treturn cb;\n\t}\n\n\tpublic function cb(value:Int):Void {\n\t\tg();\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDirectlyCalledPublicMethodStillFlagged(): Void {
		// The capture gate is about a VALUE reference: a method only ever CALLED keeps
		// its `Info` finding.
		final src: String =
			'class C {\n\tpublic function m():Void {\n\t\tcb(1);\n\t}\n\n\tpublic function cb(value:Int):Void {\n\t\tg();\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testParenthesizedCalleeStillFlagged(): Void {
		// Callee position propagates through a `ParenExpr`: `(cb)(1)` is a direct call,
		// not a capture, so the finding survives.
		final src: String =
			'class C {\n\tpublic function m():Void {\n\t\t(cb)(1);\n\t}\n\n\tpublic function cb(value:Int):Void {\n\t\tg();\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testComputedCalleeNotFlagged(): Void {
		// A callee the call site COMPUTES rather than names hands both functions to an
		// expression that selects between them as VALUES — a capture, so neither is
		// flagged.
		final src: String =
			'class C {\n\tpublic function m(cond:Bool):Void {\n\t\t(cond ? cb : alt)(1);\n\t}\n\n\tpublic function cb(value:Int):Void {\n\t\tg();\n\t}\n\n\tpublic function alt(other:Int):Void {\n\t\tg();\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDynamicFunctionParameterNotFlagged(): Void {
		// `dynamic` marks a reassignable callback slot — an assigner elsewhere relies
		// on the signature, so an unreferenced param in the default body is by
		// design, not dead code. The whole function is skipped, never autofixed.
		final src: String =
			'class C {\n\tpublic static dynamic function cb(value:Bool):Void {}\n\n\tpublic static function assign():Void {\n\t\tcb = v -> trace(v);\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testRenameConflictSkipped(): Void {
		// `_dup` already exists, so renaming the unused `dup` to `_dup` would collide —
		// the rename is skipped even with `renameSilence` opted in, and the finding is
		// left as a manual-review `Info`.
		final src: String = 'class C {\n\tpublic function f(_dup:Int, dup:Int):Int {\n\t\treturn _dup;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(src, applyFix(src, true));
	}

	public function testOptionalParameterRenamed(): Void {
		// An optional parameter keeps its `?` — only the name token gains the `_` prefix.
		final src: String = 'class C {\n\tpublic function f(?value:String):Void {}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('class C {\n\tpublic function f(?_value:String):Void {}\n}', applyFix(src, true));
	}

	/**
	 * A parameter referenced only from inside a local `inline function` is USED - the helper
	 * captures it. `LocalInlineFnStmt` opens a scope frame of its own now, and the frame nests:
	 * were it isolating, the capture would stop counting and the method's parameter would read as
	 * dead. (The check's own scan is textual and would have kept it either way; this pins the
	 * intent so a future switch to a resolver-backed scan cannot regress it silently.)
	 */
	public function testParameterCapturedByInlineHelperNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic function f(value:Int):Void {\n\t\tinline function h():Int return value;\n\t\tg(h());\n\t}\n}')
				.length
		);
	}

	/**
	 * DOCUMENTED GAP, deliberately pinned. The parameters of the local `inline function` itself
	 * are out of this check's reach: it enumerates `RefShape.functionKinds` units, and
	 * `LocalInlineFnStmt` is not one - unlike its plain twin `LocalFnStmt`, which IS. The
	 * plain-form assertion below is the control.
	 *
	 * Closing it means adding the kind to `functionKinds` / `localFunctionKinds`, which was
	 * measured (suite green, byte-identical findings on two real trees) but NOT taken: seven
	 * ops-layer sites hardcode `kind == 'LocalFnStmt'` to tell a local function from a METHOD
	 * (`CallSites`, `ChangeSig`, `RemoveParam`, `ExtractVar`, `ExtractMethod`, `InlineMethod`,
	 * `RefactorSupport`), and this check's own `Warning` arm removes a parameter through
	 * `RemoveParam`. An inline helper reaching those as a "method" takes the wrong call-set
	 * proof, so the extension belongs in a slice that fixes them together.
	 */
	public function testInlineHelperOwnParameterNotYetReached(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic function f():Void {\n\t\tinline function h(dead:Int):Int return 1;\n\t\tg(h(2));\n\t}\n}')
				.length
		);
		final plain: Array<Violation> = violations(
			'class C {\n\tpublic function f():Void {\n\t\tfunction h(dead:Int):Int return 1;\n\t\tg(h(2));\n\t}\n}'
		);
		Assert.equals(1, plain.length, 'the plain local-function control must still be flagged');
		Assert.equals('unused parameter \'dead\'', plain[0].message);
	}

	private function violations(src: String): Array<Violation> {
		return new UnusedParameter().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Apply the check's own fix edits to `src`; `renameSilence` opts the `Info` silence-rename in, as an `apqlint.json` would. */
	private function applyFix(src: String, renameSilence: Bool = false): String {
		final check: UnusedParameter = new UnusedParameter();
		if (renameSilence) check.setConfigResolver(_ -> LintConfig.parse('{"rules": {"unused-parameter": {"renameSilence": true}}}'));
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
