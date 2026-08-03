package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-case-body-fitline — REAL `FitLine` semantics for the case-body
 * placement knobs (`sameLine.caseBody` / `sameLine.expressionCase`) on
 * `HxCaseBranch.body` / `HxDefaultBranch.stmts`.
 *
 * Before this slice both knobs understood only `Same` / `Keep` / `Next`:
 * the runtime `_flatCase` gate answered a BOOLEAN "flatten now?", so
 * `FitLine` matched no arm and degenerated to `Next` — every body broke,
 * including bodies that trivially fit. The slice adds the sibling
 * `_fitCase` gate, which hands the body to
 * `anyparse.format.BodyFit.fitLineLayout` — the one emitter that also
 * serves `WriterLowering.buildBodyFitExpr`'s bare-Ref `FitLine` bodies
 * (`return` / `if` / `for`).
 *
 * TWO OUTCOMES, and which one applies is NOT a width question:
 *
 *  - The body can render on one line (`WrapList.flatLength >= 0`, i.e. no
 *    hardline anywhere in its Doc) → `BodyGroup(Nest(cols, [Line, body]))`,
 *    and the renderer's `fitsFlat` decides from the live column (the
 *    `case <patterns>:` header is already emitted) plus the flat width of
 *    ` <body>` including its `;` and any folded trailing comment.
 *  - The body cannot (a block, a wrap cascade that refuses one line, a
 *    source-multi-line literal the emitter keeps broken) → it GLUES to the
 *    label, the same shape `Same` gives, with no measurement at all.
 *
 * The flat-length question is asked FIRST, and that ordering is the whole
 * idempotence story: `Renderer.fitsFlat` DEFERS a nested `BodyGroup` while
 * `WrapList.flatLength` DESCENDS one, and the writer wraps
 * source-multi-line literals in a `BodyGroup` and single-line ones not — so
 * measuring first answered differently for the two source shapes of ONE
 * AST, and `fmt` needed a second pass to settle (pinned below by the
 * 3-pass and two-source-shapes tests).
 *
 * BOUNDARY CONTRACT, and its scope: on the MEASURED outcome a case line of
 * exactly `maxLineLength` columns stays inline and one column more breaks
 * (`Group` fit is `<= lineWidth`; no `width + 1` calibration here). The
 * GLUE outcome is placed without measurement, so its case line may exceed
 * `maxLineLength` and keeps growing with the header — measured:
 * `case 1: if (<114 c's>) {` renders at 141 columns under
 * `maxLineLength: 140`. That is not a fit bug; it is the same
 * unconditional glue `Same` / `Keep` give, and the same one a block body
 * gets from `sameLine.ifBody` / `forBody` / `whileBody`.
 *
 * COMPOSITION:
 *  - `refuseFlatOnComplexExpr` wins over the fit measurement — an
 *    `A && B` body breaks even when it fits.
 *  - `alignInlineSwitchCaseBody` reaches the fit path as `BodyFit`'s
 *    `nestGluedBody`: LIVE on the glue outcome (whose body has inner lines
 *    that may want the `+1` continuation indent), and provably inert on the
 *    measured outcome — a body that reaches it holds no hardline at all, so
 *    there is no inner line for a `Nest` to move.
 *  - Comments: a case-label trailing comment refuses the fit path outright
 *    (it would land on the wrong side of the emitter-owned separator, and
 *    it forces a physical break regardless) and an own-line comment before
 *    the body keeps the break; a comment trailing the BODY rides inline and
 *    counts toward the fit measure.
 *  - `flatChildOpt`'s child-policy fanout stays gated on the COMMITTED
 *    `_flatCase` only — pinned, because the fit path's own placement is
 *    still undecided at that point.
 *
 * Per `feedback_unit_test_trivia_writer.md`: the knobs are visible only
 * through `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxCaseBodyFitLineSliceTest extends Test {

	/** Case line renders at 3 tabs; `case 1: foo(aaaaaaaaaa);` is 24 columns, so 12 + 24 = 36 is the exact fit. */
	private static final BOUNDARY_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1: foo(aaaaaaaaaa);\n\t\t}\n\t}\n}\n';

	/** `case 3: baz(); // tail` is 22 columns at 3 tabs → 34 is the exact fit WITH the trailing comment counted. */
	private static final TRAIL_COMMENT_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 3: baz(); // tail\n\t\t}\n\t}\n}\n';

	/**
	 * The user-reported shape (anonymised): an expression-position switch
	 * whose array-pattern cases carry one-line values, one of which
	 * overflows `maxLineLength`.
	 */
	private static final EXPR_SWITCH_SRC: String = 'class E {\n'
		+ '\tfunction pick(node:Shape, kind:String, current:Bool, tint:Int = 0):Prop {\n'
		+ '\t\treturn switch [node.shapeInfo.kind, kind] {\n'
		+ '\t\t\tcase [KindData.KIND_RECTANGLE_SHAPE, KindData.KIND_RECTANGLE_STROKE]: '
		+ 'LineTint(current ? cast(node, RectangleShape).lineTint : tint);\n'
		+ '\t\t\tcase [KindData.KIND_OVAL_SHAPE, KindData.KIND_OVAL_STROKE]: LineTint(current ? cast(node, OvalShape).lineTint : tint);\n'
		+ '\t\t\tcase _: Tint(current ? node.tint : tint);\n' + '\t\t};\n' + '\t}\n' + '}\n';

	/**
	 * ω-case-body-fitline-idempotence — a case body whose value is an
	 * object literal the object-literal cascade refuses to keep on one line.
	 * The FIRST format pass sees a single-line source literal, the SECOND
	 * sees the broken one; the case-body placement must not notice the
	 * difference.
	 */
	private static final FORCED_MULTILINE_BODY_SRC: String =
		'class R {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 4: obj = {a: 1, b: 2, c: 3, d: 4, e: 5};\n\t\t}\n\t}\n}\n';

	public function new(): Void {
		super();
	}

	public function testConfigLoaderMapsFitLineForBothKeys(): Void {
		// The JSON value already PARSED before this slice; what it now means
		// at runtime is pinned by the layout tests below (this one alone
		// also passes on the pre-slice engine).
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}'
		);
		Assert.equals(BodyPolicy.FitLine, opts.caseBody);
		Assert.equals(BodyPolicy.FitLine, opts.expressionCase);
	}

	public function testCaseBodyFitLineFlattensShortStatementCase(): Void {
		final src: String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out: String = write(src, '{"sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'a body that fits must stay inline under caseBody=fitLine: <$out>');
	}

	public function testFitLineBoundaryIsExactlyMaxLineLength(): Void {
		// BOTH halves live in one test on purpose: the break half alone
		// does not discriminate (the pre-slice `FitLine`-degrades-to-`Next`
		// engine also breaks), so it proves the boundary only next to the
		// inline half measured one column wider.
		final fits: String = write(BOUNDARY_SRC, '{"wrapping": {"maxLineLength": 36}, "sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(
			fits.indexOf('\t\t\tcase 1: foo(aaaaaaaaaa);') != -1, 'a case line of exactly maxLineLength columns must stay inline: <$fits>'
		);
		final over: String = write(BOUNDARY_SRC, '{"wrapping": {"maxLineLength": 35}, "sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(
			over.indexOf('\t\t\tcase 1:\n\t\t\t\tfoo(aaaaaaaaaa);') != -1,
			'one column past maxLineLength must move the whole body to the next line: <$over>'
		);
	}

	public function testCaseBodyFitLineRejoinsSourceBrokenBodyThatFits(): Void {
		// FitLine is a WIDTH decision, not a source-shape one (that is
		// `Keep`'s job): an author-broken body that fits re-joins the label.
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1:\n\t\t\t\tfoo();\n\t\t}\n\t}\n}\n';
		final out: String = write(src, '{"sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'fitLine must re-join a source-broken body that fits: <$out>');
	}

	public function testCaseBodyFitLineKeepsMultiStmtBroken(): Void {
		// Paired with the single-statement twin so the fixture discriminates:
		// without the slice BOTH bodies break and the multi-stmt half alone
		// would prove nothing.
		final multi: String = write(
			'class M { function f():Void { switch (x) { case 1: foo(); bar(); } } }', '{"sameLine": {"caseBody": "fitLine"}}'
		);
		Assert.isTrue(multi.indexOf('case 1: foo();') == -1, 'a multi-statement body must stay broken under fitLine: <$multi>');
		Assert.isTrue(multi.indexOf('case 1:\n') != -1, 'expected the multiline `case 1:` header for a multi-statement body: <$multi>');
		final single: String = write(
			'class M { function f():Void { switch (x) { case 1: foo(); } } }', '{"sameLine": {"caseBody": "fitLine"}}'
		);
		Assert.isTrue(single.indexOf('case 1: foo();') != -1, 'the same body as ONE statement must inline: <$single>');
	}

	public function testCaseBodyFitLineRefusesLogicalOperatorBody(): Void {
		// refuseFlatOnComplexExpr (ω-issue-423-mech-b) wins over the fit
		// measurement — the body is far shorter than maxLineLength. The
		// non-refused twin of the same width discriminates the fixture.
		final refused: String = write(
			'class M { function f():Void { switch (x) { case 1: aa && bb; } } }', '{"sameLine": {"caseBody": "fitLine"}}'
		);
		Assert.isTrue(refused.indexOf('case 1: aa && bb;') == -1, 'refuse-flat must beat the fit measurement: <$refused>');
		Assert.isTrue(refused.indexOf('case 1:\n') != -1, 'expected the refused body on its own line: <$refused>');
		final allowed: String = write(
			'class M { function f():Void { switch (x) { case 1: aa + bb; } } }', '{"sameLine": {"caseBody": "fitLine"}}'
		);
		Assert.isTrue(allowed.indexOf('case 1: aa + bb;') != -1, 'only the logical operators refuse — `+` must inline: <$allowed>');
	}

	public function testDefaultBranchFitLineFlattens(): Void {
		final src: String = 'class M { function f():Void { switch (x) { default: qux(); } } }';
		final out: String = write(src, '{"sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(out.indexOf('default: qux();') != -1, 'HxDefaultBranch must share the case-body fitLine semantics: <$out>');
	}

	public function testWildcardCaseFitLineFlattens(): Void {
		final src: String = 'class M { function f():Void { switch (x) { case _: qux(); } } }';
		final out: String = write(src, '{"sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(out.indexOf('case _: qux();') != -1, 'a `case _` body that fits must stay inline: <$out>');
	}

	public function testExpressionCaseFitLineFlattensVarInitSwitch(): Void {
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1:\n\t\t\t\t10;\n\t\t};\n\t}\n}\n';
		final out: String = write(src, '{"sameLine": {"expressionCase": "fitLine"}}');
		Assert.isTrue(
			out.indexOf('case 1: 10;') != -1, 'an expression-position case that fits must inline under expressionCase=fitLine: <$out>'
		);
	}

	public function testExpressionCaseFitLineLeavesStatementPositionAlone(): Void {
		// The dual-flag gate dispatches on `opt._inExprPosition`: setting
		// only `expressionCase` must not reach a statement-position switch
		// (which keeps the loader's `caseBody: Next` baseline).
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1:\n\t\t\t\tfoo();\n\t\t}\n\t}\n}\n';
		final out: String = write(src, '{"sameLine": {"expressionCase": "fitLine"}}');
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'expressionCase=fitLine must not reach statement-position cases: <$out>');
		// Discriminator: the SAME source under the statement-position knob
		// does inline, so the miss above is the dispatch, not a dead fitLine.
		final viaCaseBody: String = write(src, '{"sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(
			viaCaseBody.indexOf('case 1: foo();') != -1, 'caseBody=fitLine must reach the same statement-position case: <$viaCaseBody>'
		);
	}

	public function testExpressionCaseFitLineBreaksOverWideBodyWholesale(): Void {
		final out: String = write(
			EXPR_SWITCH_SRC,
			'{"wrapping": {"maxLineLength": 140}, "indentation": {"alignInlineSwitchCaseBody": true},'
			+ ' "sameLine": {"expressionCase": "fitLine"}}'
		);
		Assert.isTrue(
			out.indexOf('KindData.KIND_RECTANGLE_STROKE]:\n\t\t\t\tLineTint(') != -1,
			'the over-wide case must move its WHOLE body to the next line: <$out>'
		);
		Assert.isTrue(out.indexOf('LineTint(current\n') == -1, 'the over-wide body must not split inside the value call parens: <$out>');
		Assert.isTrue(
			out.indexOf('KindData.KIND_OVAL_STROKE]: LineTint(current ? cast(node, OvalShape).lineTint : tint);') != -1,
			'the sibling case that fits must stay inline: <$out>'
		);
	}

	public function testAlignInlineSwitchCaseBodyIsInertOnTheMeasuredFitOutcome(): Void {
		// The measured outcome reaches `BodyFit` only when the body holds NO
		// hardline, so its `Nest` has no inner line to move — the knob cannot
		// change a byte. Exercised on BOTH halves of the same fixture: the
		// over-wide case (break) and its sibling that fits (flat).
		final on: String = write(EXPR_SWITCH_SRC, exprFitJson(true));
		final off: String = write(EXPR_SWITCH_SRC, exprFitJson(false));
		Assert.equals(on, off);
		// Discriminators: equality alone also holds on the pre-slice engine
		// (both sides degraded to Next). Pin that the compared output really
		// took BOTH fit outcomes.
		Assert.isTrue(
			on.indexOf('KindData.KIND_OVAL_STROKE]: LineTint(') != -1, 'the flat fit outcome must be present in the compared output: <$on>'
		);
		Assert.isTrue(
			on.indexOf('KindData.KIND_RECTANGLE_STROKE]:\n\t\t\t\tLineTint(') != -1,
			'the break fit outcome must be present in the compared output: <$on>'
		);
	}

	public function testAlignInlineSwitchCaseBodyIsHonouredOnTheGluedFitOutcome(): Void {
		// The glue outcome DOES have inner lines, so the knob is live there —
		// it is the same "does the body's container already indent relative
		// to the case line" question the committed-flat path asks, and
		// `BodyFit`'s `nestGluedBody` is how the fit path asks it.
		final src: String =
			'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1: if (a) {\n\t\t\t\tfoo();\n\t\t\t}\n\t\t}\n\t}\n}\n';
		final off: String = write(src, caseFitJson(false));
		Assert.isTrue(off.indexOf('case 1: if (a) {\n\t\t\t\t\tfoo();') != -1, 'knob off must keep the +1 continuation indent: <$off>');
		final on: String = write(src, caseFitJson(true));
		Assert.isTrue(on.indexOf('case 1: if (a) {\n\t\t\t\tfoo();') != -1, 'knob on must drop the +1 continuation indent: <$on>');
	}

	public function testTrailingBodyCommentCountsTowardTheFitMeasure(): Void {
		final fits: String = write(TRAIL_COMMENT_SRC, '{"wrapping": {"maxLineLength": 34}, "sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(
			fits.indexOf('\t\t\tcase 3: baz(); // tail') != -1, 'exact fit including the trailing comment must stay inline: <$fits>'
		);
		final breaks: String = write(TRAIL_COMMENT_SRC, '{"wrapping": {"maxLineLength": 33}, "sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(
			breaks.indexOf('\t\t\tcase 3:\n\t\t\t\tbaz(); // tail') != -1,
			'the trailing comment must push the body over the edge: <$breaks>'
		);
	}

	public function testCaseLabelTrailingCommentStillForcesBreak(): Void {
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1: // note\n\t\t\t\tfoo();\n\t\t}\n\t}\n}\n';
		final out: String = write(src, '{"sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(
			out.indexOf('case 1: // note\n\t\t\t\tfoo();') != -1, 'a comment on the case label must keep the body on the next line: <$out>'
		);
		// Discriminator: the same case without the label comment inlines.
		final bare: String = write(
			'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1:\n\t\t\t\tfoo();\n\t\t}\n\t}\n}\n',
			'{"sameLine": {"caseBody": "fitLine"}}'
		);
		Assert.isTrue(bare.indexOf('case 1: foo();') != -1, 'without the label comment the same body inlines: <$bare>');
	}

	public function testOwnLineCommentBeforeBodyStillForcesBreak(): Void {
		final src: String =
			'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 2:\n\t\t\t\t// own line\n\t\t\t\tbar();\n\t\t}\n\t}\n}\n';
		final out: String = write(src, '{"sameLine": {"caseBody": "fitLine"}}');
		Assert.isTrue(
			out.indexOf('case 2:\n\t\t\t\t// own line\n\t\t\t\tbar();') != -1,
			'an own-line comment before the body must keep the break: <$out>'
		);
		// Discriminator: the same case without the own-line comment inlines.
		final bare: String = write(
			'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 2:\n\t\t\t\tbar();\n\t\t}\n\t}\n}\n',
			'{"sameLine": {"caseBody": "fitLine"}}'
		);
		Assert.isTrue(bare.indexOf('case 2: bar();') != -1, 'without the own-line comment the same body inlines: <$bare>');
	}

	public function testKnobOffKeepsSourceShapeOnTheSameFixtures(): Void {
		// Byte-inertness of the slice: `Keep` is the shipped default for both
		// knobs, and under it neither gate fires — placement still comes off
		// the source shape. Spelled explicitly rather than relying on the
		// default so the fixture keeps testing `Keep` if a default ever moves;
		// `HxCaseBodyPolicySliceTest.testDefaultsCaseBodyKeepExpressionCaseKeep`
		// owns the defaults themselves.
		final broken: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1:\n\t\t\t\tfoo();\n\t\t}\n\t}\n}\n';
		final brokenOut: String = write(broken, '{"sameLine": {"caseBody": "keep"}}');
		Assert.isTrue(brokenOut.indexOf('case 1: foo();') == -1, 'Keep must still preserve a source-broken body: <$brokenOut>');
		final inlineSrc: String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final inlineOut: String = write(inlineSrc, '{"sameLine": {"caseBody": "keep"}}');
		Assert.isTrue(inlineOut.indexOf('case 1: foo();') != -1, 'Keep must still preserve a source-inline body: <$inlineOut>');
	}

	public function testFitLineIsIdempotentOnForcedMultilineBody(): Void {
		// BLOCKER regression: pass 1 broke the body to the next line, pass 2
		// re-joined it as `case 4: obj = {`. One `fmt --write` then left
		// `fmt --list` still reporting drift, which breaks the
		// `writeRoundTrip(s) == s` canonical gate every writer-emit op needs.
		final json: String = '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "fitLine"}}';
		final pass1: String = write(FORCED_MULTILINE_BODY_SRC, json);
		final pass2: String = write(pass1, json);
		final pass3: String = write(pass2, json);
		Assert.equals(pass1, pass2, 'fitLine must reach its fixed point in ONE pass');
		Assert.equals(pass2, pass3);
	}

	public function testFitLineOutputIsIndependentOfSourceLineShape(): Void {
		// The same AST written from a single-line source and from an
		// already-broken source must produce identical bytes: `fitsFlat`
		// DEFERS a nested `BodyGroup` (so a source-broken literal measured as
		// if it were empty), while `WrapList.flatLength` descends it. The
		// placement decision must use the descending measure.
		final json: String = '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "fitLine"}}';
		final fromInline: String = write(FORCED_MULTILINE_BODY_SRC, json);
		final broken: String = 'class R {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 4:\n\t\t\t\tobj = {\n'
			+ '\t\t\t\t\ta: 1,\n\t\t\t\t\tb: 2,\n\t\t\t\t\tc: 3,\n\t\t\t\t\td: 4,\n\t\t\t\t\te: 5\n\t\t\t\t};\n\t\t}\n\t}\n}\n';
		final fromBroken: String = write(broken, json);
		Assert.equals(fromInline, fromBroken, 'fitLine placement must not depend on the source line shape');
	}

	public function testFitLineGluesABodyThatCannotRenderFlat(): Void {
		// The resolution of the two passes above: a body whose Doc commits to
		// a hardline can never render on the case line, so measuring it is
		// meaningless. It glues — the same answer `bodyPolicyWrap`'s FitLine
		// gives a multi-line `return` / `if` body, and the same shape
		// `caseBody: same` produces.
		final json: String = '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "fitLine"}}';
		final out: String = write(FORCED_MULTILINE_BODY_SRC, json);
		Assert.isTrue(out.indexOf('case 4: obj = {') != -1, 'a body that cannot render flat glues to the label: <$out>');
		final same: String = write(FORCED_MULTILINE_BODY_SRC, '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "same"}}');
		Assert.equals(same, out, 'the glue outcome must match what caseBody=same produces for the same body');
	}

	public function testWidthDrivenBreakIsAlsoIdempotent(): Void {
		// The other half: a body with NO committed hardline is measured, and
		// re-measuring it from its own broken output must reach the same
		// verdict (the body then sits one indent deeper, still over budget).
		final json: String = '{"wrapping": {"maxLineLength": 140}, "indentation": {"alignInlineSwitchCaseBody": true},'
			+ ' "sameLine": {"expressionCase": "fitLine"}}';
		final pass1: String = write(EXPR_SWITCH_SRC, json);
		final pass2: String = write(pass1, json);
		Assert.equals(pass1, pass2, 'the width-driven break must be a fixed point too');
		Assert.isTrue(
			pass1.indexOf('KindData.KIND_RECTANGLE_STROKE]:\n\t\t\t\tLineTint(') != -1, 'the over-wide case must still break: <$pass1>'
		);
	}

	public function testFlatChildOptDoesNotFanOutOnTheFitPath(): Void {
		// `flatChildOpt('ifBody=expressionCase', …)` swaps the child policies
		// only when the body is COMMITTED to the label line (`_flatCase`).
		// The fit path leaves them alone: its own placement is decided by the
		// renderer, so forcing a child's shape from an undecided outcome
		// would be the blind propagation the expressionIf fanout warns about.
		// Reaching the fanout needs `expressionIf: next` — it sets
		// `expressionIfBody` to `Next`, which arms the case-tail barrier
		// (`tailStmtReadsExprPosition`) so a tail `if` in a statement-position
		// switch reads `ifBody` instead of `expressionIfBody`. Only then is
		// the swapped `ifBody` observable at all.
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1: if (a) foo();\n\t\t}\n\t}\n}\n';
		final base: String = '"expressionCase": "same", "ifBody": "next", "expressionIf": "next"';
		final same: String = write(src, '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "same", $base}}');
		Assert.isTrue(
			same.indexOf('case 1: if (a) foo();') != -1, 'the committed-flat path DOES fan out `ifBody` to `expressionCase`: <$same>'
		);
		final fit: String = write(src, '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "fitLine", $base}}');
		Assert.isTrue(
			fit.indexOf('case 1: if (a)\n') != -1, 'the fit path must NOT fan out `ifBody`, so the inner body still breaks: <$fit>'
		);
		Assert.isTrue(fit.indexOf('foo();') != -1, 'the inner body must survive the break: <$fit>');
	}

	/** `maxLineLength: 140` + `alignInlineSwitchCaseBody: <flag>` + expression-position fitLine. */
	private inline function exprFitJson(alignInline: Bool): String {
		return fitJson('expressionCase', alignInline);
	}

	/** Statement-position sibling of `exprFitJson`. */
	private inline function caseFitJson(alignInline: Bool): String {
		return fitJson('caseBody', alignInline);
	}

	private inline function fitJson(knob: String, alignInline: Bool): String {
		return '{"wrapping": {"maxLineLength": 140}, "indentation": {"alignInlineSwitchCaseBody": $alignInline}, "sameLine": {"$knob'
			+ '": "fitLine"}}';
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
