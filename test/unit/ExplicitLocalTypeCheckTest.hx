package unit;

import anyparse.check.Check.Violation;
import anyparse.check.ExplicitLocalType;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;

/**
 * The `explicit-local-type` check: a local `var` / `final` with no `:Type`
 * annotation is flagged (statement-position locals only; a typed local, a macro-
 * reification local, and non-local bindings are exempt). Default OFF — dropped from
 * the default set unless `apqlint.json` opts in (`enabled:true`) or an explicit rule
 * selection bypasses enablement.
 *
 * This part covers the detection and that gate, plus the autofix on a STRUCTURALLY
 * PINNED initializer — a literal, a neg-numeric, a written-generic `new`, a provably
 * non-generic bare `new T()` and a homogeneous array literal — re-stating the
 * compiler's own inference. An empty / heterogeneous array, a generic-or-unknown bare
 * `new` (`new Map()`) and `null` stay report-only.
 *
 * The read-resolved initializers live in `ExplicitLocalTypeReadFixTest`, the
 * parenthesised and check-typed ones in `ExplicitLocalTypeParenInitTest`.
 */
class ExplicitLocalTypeCheckTest extends ExplicitLocalTypeCheckTestBase {

	// --- fix: structurally-pinned shapes annotated ---

	public inline function testFixString(): Void {
		assertFixContains("final s = 'hello';", ':String');
	}

	public inline function testFixInt(): Void {
		assertFixContains('var a = 5;', ':Int');
	}

	public inline function testFixFloat(): Void {
		assertFixContains('var d = 1.5;', ':Float');
	}

	public inline function testFixBool(): Void {
		assertFixContains('final b = true;', ':Bool');
	}

	public inline function testFixNegInt(): Void {
		assertFixContains('var e = -3;', ':Int');
	}

	public inline function testFixHomogeneousIntArray(): Void {
		assertFixContains('final arr = [1, 2, 3];', ':Array<Int>');
	}

	public inline function testFixHomogeneousStringArray(): Void {
		assertFixContains("var strs = ['a', 'b'];", ':Array<String>');
	}

	public inline function testFixNewWithWrittenGenerics(): Void {
		assertFixContains('final m = new Map<String, Int>();', ':Map<String, Int>');
	}

	// --- fix: bare new with provable non-generic arity ---

	public inline function testFixBareNewBuiltin(): Void {
		assertFixContains('final sb = new StringBuf();', ':StringBuf');
	}

	public inline function testFixBareNewQualifiedBuiltin(): Void {
		assertFixContains('final b = new haxe.io.BytesBuffer();', ':haxe.io.BytesBuffer');
	}

	// --- fix: inference-resolved shapes stay report-only ---

	public inline function testSkipEmptyArray(): Void {
		assertNoFix('final empty = [];');
	}

	public inline function testSkipHeterogeneousArray(): Void {
		assertNoFix("var hetero = [1, 'x'];");
	}

	public inline function testSkipBareNew(): Void {
		assertNoFix('final bare = new Map();');
	}

	public inline function testSkipNullInit(): Void {
		assertNoFix('final nul = null;');
	}

	public inline function testFixBareNewQualifiedPath(): Void {
		// `Path` is a whitelisted non-generic constructor type -> the written name verbatim.
		assertFixContains("final p = new haxe.io.Path('x');", 'p:haxe.io.Path');
	}

	// --- detection ---

	public function testUntypedVarFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var a = 5;'));
		Assert.equals(1, vs.length);
		Assert.equals('explicit-local-type', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testUntypedFinalFlagged(): Void {
		Assert.equals(1, violations(wrap('final a = 5;')).length);
	}

	public function testTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a:Int = 5;')).length);
	}

	public function testTypedFinalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final a:String = "x";')).length);
	}

	public function testParameterNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(p):Void {}\n}').length);
	}

	public function testNoInitUntypedFlaggedNoFix(): Void {
		final src: String = wrap('var a;');
		Assert.equals(1, violations(src).length);
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	public function testMacroLocalSkipped(): Void {
		final src: String = 'class C {\n\tmacro static function f() {\n\t\treturn macro {\n\t\t\tvar inside = 5;\n\t\t};\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFixBareNewIndexedPlainClass(): Void {
		assertFixIdx(
			wrap('final t = new Widget();'), [{ file: 'Widget.hx', source: 'class Widget {\n\tpublic function new() {}\n}' }], ':Widget'
		);
	}

	public function testBareNewGenericDeclSkipped(): Void {
		assertNoFixIdx(wrap('final b = new Box();'), [{ file: 'Box.hx', source: 'class Box<T> {\n\tpublic function new() {}\n}' }]);
	}

	public function testBareNewAmbiguousAritySkipped(): Void {
		assertNoFixIdx(wrap('final w = new Widget();'), [
			{ file: 'Widget.hx', source: 'class Widget {\n\tpublic function new() {}\n}' },
			{ file: 'other/Widget.hx', source: 'class Widget<T> {\n\tpublic function new() {}\n}' }
		]);
	}

	public function testBareNewIndexShadowedBuiltinSkipped(): Void {
		assertNoFixIdx(wrap('final s = new StringBuf();'), [
			{ file: 'StringBuf.hx', source: 'class StringBuf<T> {\n\tpublic function new() {}\n}' }
		]);
	}

	public function testIdempotentOnTyped(): Void {
		final src: String = wrap('var a:Int = 5;');
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	// --- enablement gate ---

	public function testDefaultOffSuppressed(): Void {
		Assert.equals(0, runGated(wrap('var a = 5;'), '{}', true).length);
	}

	public function testOptInEnabled(): Void {
		final json: String = '{"rules":{"explicit-local-type":{"enabled":true}}}';
		Assert.equals(1, runGated(wrap('var a = 5;'), json, true).length);
	}

	public function testExplicitSelectionBypassesGate(): Void {
		// applyEnablement=false is the --rule path: a DefaultOff rule runs regardless.
		Assert.equals(1, runGated(wrap('var a = 5;'), '{}', false).length);
	}

	public function testNoqaSuppression(): Void {
		final json: String = '{"rules":{"explicit-local-type":{"enabled":true}}}';
		Assert.equals(0, runGated(wrap('var a = 5; // noqa'), json, true).length);
	}

	// --- registry / robustness ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('explicit-local-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('explicit-local-type'));
		Assert.equals(177, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { var a = 5;').length);
	}

	/**
	 * The arity proof may live OUTSIDE the report scope. `Widget` is declared only in the configured
	 * RESOLUTION library, so the report index answers "no such name" and all the ladder used to have
	 * left was the whitelist — a guess about always-in-scope stdlib names, which a project's own
	 * libraries are not. The annotation copies the WRITTEN name a token away from the `new` that
	 * already spells it, so it resolves identically and needs no import.
	 */
	public function testBareNewOfAResolutionScopedTypeIsNamed(): Void {
		Assert.isTrue(scopedFixText(wrap('final w = new Widget();'), [
			{ file: 'lib/ext/Widget.hx', source: 'package ext;\n\nclass Widget {\n\tpublic function new() {}\n}' }
		]).indexOf(':Widget') >= 0);
	}

	/** The discriminating half: a GENERIC library type stays report-only — a bare `:Widget` is a compile error. */
	public function testBareNewOfAGenericResolutionScopedTypeStaysReportOnly(): Void {
		Assert.isTrue(scopedFixText(wrap('final w = new Widget();'), [
			{ file: 'lib/ext/Widget.hx', source: 'package ext;\n\nclass Widget<T> {\n\tpublic function new() {}\n}' }
		]).indexOf(':Widget') < 0);
	}

	/**
	 * The REPORT index is asked FIRST, and its answer is final. A project type shadows a library's
	 * same-named one, so the library's disagreeing arity must not dissolve the project's proof —
	 * asking the union instead would leave `typeParamArityOf` null here and decline a sound
	 * annotation.
	 */
	public function testReportScopeArityWinsOverADisagreeingResolutionScope(): Void {
		Assert.isTrue(scopedFixText(wrap('final w = new Widget();'), [
			{ file: 'lib/ext/Widget.hx', source: 'package ext;\n\nclass Widget<T> {\n\tpublic function new() {}\n}' }
		], [{ file: 'Widget.hx', source: 'class Widget {\n\tpublic function new() {}\n}' }]).indexOf(':Widget') >= 0);
	}

	/** And the same precedence the other way: a GENERIC project type declines even though the library's is not. */
	public function testReportScopeGenericityWinsOverANonGenericResolutionScope(): Void {
		Assert.isTrue(scopedFixText(
			wrap('final w = new Widget();'),
			[
				{ file: 'lib/ext/Widget.hx', source: 'package ext;\n\nclass Widget {\n\tpublic function new() {}\n}' }
			],
			[
				{ file: 'Widget.hx', source: 'class Widget<T> {\n\tpublic function new() {}\n}' }
			]
		).indexOf(':Widget') < 0);
	}

	public function testBareNewWhitelistedAmbiguousAritySkipped(): Void {
		// StringBuf is whitelisted as non-generic, but the index disagrees on its arity
		// (arity 0 vs arity 1). Ambiguity must never prove non-genericity: the whitelist
		// fallback must NOT fire, so this stays report-only (no fix).
		assertNoFixIdx(wrap('final s = new StringBuf();'), [
			{ file: 'a/StringBuf.hx', source: 'class StringBuf {\n\tpublic function new() {}\n}' },
			{ file: 'b/StringBuf.hx', source: 'class StringBuf<T> {\n\tpublic function new() {}\n}' }
		]);
	}

	/**
	 * Every shape above that stays report-only now says WHY, on the finding itself.
	 *
	 * A full-ruleset run over an 851-file tree reported all 367 of this rule's findings as
	 * `its fix was called for these findings and returned no edit; the check declares neither
	 * NoAutofix nor a decline reason` — which reads as a rule that cannot fix, while the ladder
	 * annotates five of seven ordinary shapes on the same engine. The residue is the hard cases,
	 * and that is a sentence the reader was owed: measured with the reasons in place, those 367
	 * split 357 uninferable / 7 initializer-less / 3 inadmissible.
	 */
	public function testFixSaysWhyEachSkippedShapeGotNoAnnotation(): Void {
		assertDeclineReason('var m = new Map();', 'no structural rule names the initializer type');
		assertDeclineReason('var e = [];', 'no structural rule names the initializer type');
		assertDeclineReason('var n;', 'carries no initializer');
		assertDeclineReason('var d = (v : Dynamic);', 'which an annotation must not spell');
		// The other half: a shape the ladder DOES name declined nothing, so it carries no reason.
		final annotated: String = wrap('var a = 5;');
		final check: ExplicitLocalType = new ExplicitLocalType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: annotated }], new HaxeQueryPlugin());
		Assert.equals(1, check.fix(annotated, vs, new HaxeQueryPlugin()).length);
		Assert.isNull(vs[0].declineReason, 'a finding the ladder answers declined nothing');
	}

	/** `body`'s one finding gets no edit, and its `declineReason` names `gate`. */
	private function assertDeclineReason(body: String, gate: String): Void {
		final src: String = wrap(body);
		final check: ExplicitLocalType = new ExplicitLocalType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length, 'one finding for: $body');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length, 'the shape is report-only: $body');
		final reason: Null<String> = vs[0].declineReason;
		Assert.notNull(reason, 'a declined finding must say why: $body');
		if (reason != null) Assert.isTrue(reason.indexOf(gate) >= 0, 'the reason names the gate that closed - got: $reason');
	}

	// --- helpers ---

	private function runGated(source: String, json: String, applyEnablement: Bool): Array<Violation> {
		function resolver(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin(), [new ExplicitLocalType()], resolver, applyEnablement);
	}

}
