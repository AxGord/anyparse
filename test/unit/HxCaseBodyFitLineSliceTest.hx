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
 * `_fitCase` gate, which emits `BodyGroup(Nest(cols, [Line, body]))` —
 * the same Doc shape `WriterLowering.buildBodyFitExpr` builds for a
 * bare-Ref `FitLine` body (`return` / `if` / `for`). The renderer's own
 * `fitsFlat` then decides: it sees the live column (the `case
 * <patterns>:` header is already emitted) plus the flat width of
 * ` <body>` including the body's `;` and any folded trailing comment.
 *
 * Boundary contract (pinned below): a case line of EXACTLY
 * `maxLineLength` columns stays inline; one column more breaks. No
 * `width + 1` calibration here — `Group` fit is `<= lineWidth`.
 *
 * Composition contract:
 *  - `refuseFlatOnComplexExpr` wins over the fit measurement — an
 *    `A && B` body breaks even when it fits.
 *  - `alignInlineSwitchCaseBody` is a no-op under `FitLine`: its purpose
 *    is to avoid a second indent level on a COMMITTED-inline body that
 *    wraps internally, and `FitLine` never produces that state (a body
 *    that cannot render flat makes the group break instead).
 *  - Comments keep their existing behaviour: a case-label trailing
 *    comment and an own-line comment before the body both force the
 *    break; a comment trailing the body itself rides inline and counts
 *    toward the fit measure.
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

	public function testAlignInlineSwitchCaseBodyIsInertUnderFitLine(): Void {
		final on: String = write(
			EXPR_SWITCH_SRC,
			'{"wrapping": {"maxLineLength": 140}, "indentation": {"alignInlineSwitchCaseBody": true},'
			+ ' "sameLine": {"expressionCase": "fitLine"}}'
		);
		final off: String = write(
			EXPR_SWITCH_SRC,
			'{"wrapping": {"maxLineLength": 140}, "indentation": {"alignInlineSwitchCaseBody": false},'
			+ ' "sameLine": {"expressionCase": "fitLine"}}'
		);
		Assert.equals(on, off);
		// Discriminator: equality alone also holds on the pre-slice engine
		// (both sides degrade to Next). Pin that the compared output really
		// took the fit path.
		Assert.isTrue(
			on.indexOf('KindData.KIND_OVAL_STROKE]: LineTint(') != -1,
			'the compared output must be the fit layout, not the all-broken one: <$on>'
		);
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
		// Byte-inertness of the slice: with the shipped defaults the two
		// gates both stay false and `Keep` still drives placement off the
		// source shape.
		final broken: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase 1:\n\t\t\t\tfoo();\n\t\t}\n\t}\n}\n';
		final brokenOut: String = write(broken, '{"sameLine": {"caseBody": "keep"}}');
		Assert.isTrue(brokenOut.indexOf('case 1: foo();') == -1, 'Keep must still preserve a source-broken body: <$brokenOut>');
		final inlineSrc: String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final inlineOut: String = write(inlineSrc, '{"sameLine": {"caseBody": "keep"}}');
		Assert.isTrue(inlineOut.indexOf('case 1: foo();') != -1, 'Keep must still preserve a source-inline body: <$inlineOut>');
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
