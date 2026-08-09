package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Linter;
import anyparse.check.PreferCaseGuard;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.check.Check;

/**
 * The `prefer-case-guard` check: a switch-case branch whose body is exactly one
 * else-less `if` is flagged `Info`, and the fix rewrites it as
 * `case P if (cond): <if-body>`.
 *
 * The conversion is NOT universally equivalent, which is what every gate below
 * defends. A case guard that evaluates FALSE resumes pattern matching, while
 * `case P: if (c) ...` consumes the match and does nothing; and guarding a case of
 * an exhaustiveness-checked subject (an enum / enum abstract) is a compile error.
 * So the fixtures come in pairs: the shape that converts, and the neighbouring
 * shape that must not.
 *
 * Width fixtures name their file `C.hx` and rely on the repository's OWN
 * `hxformat.json` (`maxLineLength` 140, tab width 4) — the same convention
 * `FoldStringLiteralsCheckTest` documents.
 */
class PreferCaseGuardCheckTest extends Test {

	/** `maxLineLength` from the repository's own `hxformat.json`, which `C.hx` resolves to. */
	private static inline final LINE_WIDTH: Int = 140;

	/** Columns before the `case` keyword in a `sw()` fixture: three tabs at tab width 4. */
	private static inline final CASE_COLUMN: Int = 12;

	/** Columns a `sw()` width fixture spends outside the pattern text: `case ""` plus ` if (b):`. */
	private static inline final LABEL_OVERHEAD: Int = 15;

	/** The longest pattern whose converted label still fits `LINE_WIDTH`. */
	private static inline final WIDEST_FITTING_PATTERN: Int = LINE_WIDTH - CASE_COLUMN - LABEL_OVERHEAD;

	public function testBlockBodyFlagged(): Void {
		final vs: Array<Violation> = violations(sw('case "a": if (b) {\n\t\t\t\tp();\n\t\t\t\tq();\n\t\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-case-guard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this case body is a single if; write it as a case guard', vs[0].message);
	}

	public function testBareStatementBodyFlagged(): Void {
		Assert.equals(1, violations(sw('case "a": if (b) p();')).length);
	}

	public function testMultiPatternFlagged(): Void {
		Assert.equals(1, violations(sw('case "a", "b": if (c) p();')).length);
	}

	/** The `if` on its own line below the label converts exactly as the same-line form does. */
	public function testIfOnNextLineFlagged(): Void {
		Assert.equals(1, violations(sw('case "a":\n\t\t\t\tif (b) p();')).length);
	}

	/** Two convertible branches in one switch are two independent findings. */
	public function testTwoBranchesFlaggedIndependently(): Void {
		Assert.equals(2, violations(sw('case "a": if (b) p();\n\t\t\tcase "z": if (c) q();')).length);
	}

	public function testDefaultBranchPresentNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p();\n\t\t\tdefault: q();')).length);
	}

	public function testWildcardCaseNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p();\n\t\t\tcase _: q();')).length);
	}

	/** A bare lowercase pattern is a BINDER, so it matches every subject exactly as `_` does. */
	public function testBareBinderCatchAllNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p();\n\t\t\tcase other: q();')).length);
	}

	/** `case var x:` is the same catch-all through a different node shape. */
	public function testCapturePatternNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p();\n\t\t\tcase var x: q();')).length);
	}

	/** A LATER sibling repeating the pattern is exactly what a false guard would fall into. */
	public function testLaterDuplicatePatternNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p();\n\t\t\tcase "a": q();')).length);
	}

	/** An EARLIER duplicate is dead code the false guard can never reach, so the branch still converts. */
	public function testEarlierDuplicatePatternStillFlagged(): Void {
		Assert.equals(1, violations(sw('case "a": q();\n\t\t\tcase "a": if (b) p();')).length);
	}

	public function testElsePresentNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p(); else q();')).length);
	}

	/**
	 * An already-guarded branch is refused by the LABEL gate, and that is the only mechanism: a
	 * guard is written between the last pattern and the label's `:`, so the span the gate
	 * requires to be a bare colon can never be one. A separate AST-level "is it guarded" clause
	 * was removed as provably unreachable rather than kept as an untestable belt.
	 */
	public function testExistingGuardNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a" if (g): if (b) p();')).length);
	}

	public function testConstructorCallPatternNotFlagged(): Void {
		Assert.equals(0, violations(sw('case Some(x): if (b) p();')).length);
	}

	/** A bare CAPITALISED pattern is an unqualified enum constructor, unresolvable and not convertible. */
	public function testBareCapitalisedPatternNotFlagged(): Void {
		Assert.equals(0, violations(sw('case LIST: if (b) p();')).length);
	}

	public function testArrayPatternNotFlagged(): Void {
		Assert.equals(0, violations(sw('case [x, y]: if (b) p();')).length);
	}

	public function testOrPatternNotFlagged(): Void {
		Assert.equals(0, violations(sw('case 1 | 2: if (b) p();')).length);
	}

	public function testTwoStatementBodyNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p();\n\t\t\t\tq();')).length);
	}

	public function testEmptyIfBodyNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) {}')).length);
	}

	/**
	 * A body holding only a COMMENT is empty as far as the tree is concerned, and a guard
	 * over it would control nothing. Distinct from the `{}` fixture above, which the
	 * empty-interior test rejects on its own; this one pins the child-count gate.
	 */
	public function testCommentOnlyIfBodyNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) {\n\t\t\t\t// note\n\t\t\t}')).length);
	}

	/** An expression switch must stay exhaustive, so no arm of one is ever a candidate. */
	public function testExpressionSwitchNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(s: String): Void {\n\t\tfinal v = switch s {\n'
			+ '\t\t\tcase "a": if (b) p();\n\t\t\tcase "z": q();\n\t\t};\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A conditional-compilation region inside the moved body is a documented safe miss. */
	public function testConditionalCompilationBodyNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) {\n\t\t\t\t#if sys\n\t\t\t\tp();\n\t\t\t\t#end\n\t\t\t}')).length);
	}

	/** A comment between the label colon and the `if` has nowhere to go once the `if` moves into the label. */
	public function testCommentBeforeIfNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": /* note */ if (b) p();')).length);
	}

	public function testLabelAtMaxLineLengthFlagged(): Void {
		Assert.equals(1, violations(sw('case "${repeat(WIDEST_FITTING_PATTERN)}": if (b) p();')).length);
	}

	public function testLabelOverMaxLineLengthNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "${repeat(WIDEST_FITTING_PATTERN + 1)}": if (b) p();')).length);
	}

	/** An out-of-scope dotted head cannot be resolved, and is accepted rather than skipped. */
	public function testOutOfScopeDottedHeadFlagged(): Void {
		Assert.equals(1, violations(sw('case Codes.DOWN: if (b) p();\n\t\t\tcase Codes.UP: q();')).length);
	}

	/** A dotted head that resolves to a plain class is a constant holder, not an exhaustive subject. */
	public function testInScopeClassConstantFlagged(): Void {
		final other: String = 'class Codes {\n\tpublic static final DOWN: Int = 0;\n}';
		Assert.equals(1, scopedViolations(other, sw('case Codes.DOWN: if (b) p();')).length);
	}

	/** An in-scope `enum abstract` subject is exhaustiveness-checked, so guarding any arm breaks the build. */
	public function testInScopeEnumAbstractNotFlagged(): Void {
		final other: String = 'enum abstract E(Int) {\n\tfinal A = 0;\n\tfinal B = 1;\n}';
		Assert.equals(0, scopedViolations(other, sw('case E.A: if (b) p();\n\t\t\tcase E.B: q();')).length);
	}

	/** The same for a real `enum`, reached through a qualified constructor path. */
	public function testInScopeEnumNotFlagged(): Void {
		final other: String = 'enum E {\n\tA;\n\tB;\n}';
		Assert.equals(0, scopedViolations(other, sw('case E.A: if (b) p();\n\t\t\tcase E.B: q();')).length);
	}

	/** A qualified `pkg.E.A` path is checked segment by segment, so the enum in the middle is still seen. */
	public function testInScopeQualifiedEnumNotFlagged(): Void {
		final other: String = 'package pkg;\n\nenum abstract E(Int) {\n\tfinal A = 0;\n}';
		Assert.equals(0, scopedViolations(other, sw('case pkg.E.A: if (b) p();')).length);
	}

	public function testFixUnwrapsBlock(): Void {
		final edits: Array<{ span: Span, text: String }> = fixEdits(sw('case "a": if (b) {\n\t\t\t\tp();\n\t\t\t\tq();\n\t\t\t}'));
		Assert.equals(1, edits.length);
		Assert.equals(' if (b): p();\n\t\t\t\tq();', edits[0].text);
	}

	public function testFixBareStatement(): Void {
		final edits: Array<{ span: Span, text: String }> = fixEdits(sw('case "a": if (b) p();'));
		Assert.equals(1, edits.length);
		Assert.equals(' if (b): p();', edits[0].text);
	}

	/** The guard attaches after the LAST pattern of a multi-pattern list, binding to the whole list. */
	public function testFixMultiPatternAttachesAfterLastPattern(): Void {
		Assert.isTrue(applyFixOnce(sw('case "a", "b": if (c) p();')).indexOf('case "a", "b" if (c):') != -1);
	}

	public function testFixOutputConvertsBlockBody(): Void {
		final out: String = applyFixOnce(sw('case "a": if (b) {\n\t\t\t\tp();\n\t\t\t\tq();\n\t\t\t}'));
		Assert.isTrue(out.indexOf('case "a" if (b):') != -1);
		Assert.equals(-1, out.indexOf('if (b) {'));
	}

	/** A comment trailing the moved statement rides along with it. */
	public function testFixKeepsTrailingComment(): Void {
		final out: String = applyFixOnce(sw('case "a": if (b) p(); // note'));
		Assert.isTrue(out.indexOf('case "a" if (b):') != -1);
		Assert.isTrue(out.indexOf('// note') != -1);
	}

	/** A comment INSIDE the moved block body survives the unwrap. */
	public function testFixKeepsInteriorComment(): Void {
		final out: String = applyFixOnce(sw('case "a": if (b) {\n\t\t\t\tp(); // inner\n\t\t\t\tq();\n\t\t\t}'));
		Assert.isTrue(out.indexOf('// inner') != -1);
		Assert.isTrue(out.indexOf('case "a" if (b):') != -1);
	}

	/** A converted branch carries a guard, so it can never report again. */
	public function testFixOutputNoLongerReports(): Void {
		Assert.equals(0, violations(applyFixOnce(sw('case "a": if (b) {\n\t\t\t\tp();\n\t\t\t\tq();\n\t\t\t}'))).length);
	}

	/** A second fix pass over the converted file is byte-stable. */
	public function testFixOutputIsByteStable(): Void {
		final once: String = applyFixOnce(sw('case "a": if (b) {\n\t\t\t\tp();\n\t\t\t\tq();\n\t\t\t}'));
		Assert.equals(once, applyFixOnce(once));
	}

	/** A single-quoted plain literal is a constant like any other -- it carries a `Literal` child, not an interpolation. */
	public function testSingleQuotedPatternFlagged(): Void {
		Assert.equals(1, violations(sw("case 'a': if (b) p();")).length);
	}

	/** `"a"` and `'a'` are ONE value in two quotings, so the later arm is exactly what a false guard falls into. */
	public function testQuoteVariantDuplicateNotFlagged(): Void {
		Assert.equals(0, violations(sw("case \"a\": if (b) p();\n\t\t\tcase 'a': q();")).length);
	}

	/** An INTERPOLATED literal is not a constant pattern at all, so the switch is refused. */
	public function testInterpolatedPatternNotFlagged(): Void {
		Assert.equals(0, violations(sw("case 'a$x': if (b) p();")).length);
	}

	/**
	 * A literal whose raw content carries an escape or a quote can spell one value
	 * differently per quoting, so its duplicate key cannot be trusted and the switch is
	 * refused -- the conservative direction.
	 */
	public function testEscapedContentPatternNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a\\"b": if (b) p();\n\t\t\tcase "z": q();')).length);
	}

	/**
	 * A switch MIXING literal and dotted-path patterns is refused: `Cst.A` may hold `"a"`,
	 * so a false guard on the literal arm could silently activate the dotted one, and
	 * nothing in the source shows the collision.
	 */
	public function testMixedLiteralAndDottedPatternsNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b) p();\n\t\t\tcase Cst.A: q();')).length);
	}

	/** The all-dotted control for the mixed-class gate. */
	public function testAllDottedPatternsFlagged(): Void {
		Assert.equals(1, violations(sw('case Cst.A: if (b) p();\n\t\t\tcase Cst.B: q();')).length);
	}

	/** The all-literal control for the mixed-class gate. */
	public function testAllLiteralPatternsFlagged(): Void {
		Assert.equals(1, violations(sw('case "a": if (b) p();\n\t\t\tcase "z": q();')).length);
	}

	/** An empty if-then converts to a dead bare `;` under the label, so it is refused. */
	public function testEmptyIfStatementBodyNotFlagged(): Void {
		Assert.equals(0, violations(sw('case "a": if (b);')).length);
	}

	/**
	 * A `typedef` in scope pointing at an enum abstract is followed ONE hop: without it the
	 * alias resolves to a `TypedefDecl`, reads as an ordinary constant holder, and the
	 * conversion fails to compile with `Unmatched patterns`.
	 */
	public function testTypedefAliasToEnumAbstractNotFlagged(): Void {
		final other: String = 'enum abstract Ek(Int) {\n\tfinal A = 0;\n\tfinal B = 1;\n}\n\ntypedef Alias = Ek;';
		Assert.equals(0, scopedViolations(other, sw('case Alias.A: if (b) p();\n\t\t\tcase Alias.B: q();')).length);
	}

	/** The control: a typedef pointing at a plain class is an ordinary constant holder and still converts. */
	public function testTypedefAliasToClassFlagged(): Void {
		final other: String = 'class Cst {\n\tpublic static final A: Int = 0;\n}\n\ntypedef Alias = Cst;';
		Assert.equals(1, scopedViolations(other, sw('case Alias.A: if (b) p();')).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-case-guard'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-case-guard'));
		final registered: Null<Check> = Linter.byId('prefer-case-guard');
		Assert.isTrue(registered is RiskyFix, 'the guard conversion is oracle-verified, never applied unverified');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** Wrap switch `branches` in a minimal parseable class + method; a case label lands at three tabs. */
	private function sw(branches: String): String {
		return 'class C {\n\tfunction f(s: String): Void {\n\t\tswitch s {\n\t\t\t$branches\n\t\t}\n\t}\n}';
	}

	private function repeat(length: Int): String {
		final buf: StringBuf = new StringBuf();
		for (_ in 0...length) buf.addChar('x'.code);
		return buf.toString();
	}

	private function violations(src: String): Array<Violation> {
		return new PreferCaseGuard().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Run over TWO files so the resolution index can see `other`'s declarations. */
	private function scopedViolations(other: String, src: String): Array<Violation> {
		return new PreferCaseGuard().run([{ file: 'Other.hx', source: other }, { file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferCaseGuard = new PreferCaseGuard();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer, `reformat` on so the minimal fixture need not be canonical. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, fixEdits(src), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
