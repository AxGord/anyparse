package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * ω-glue-width — a width answer for the `FitLine` GLUE outcome.
 *
 * Under any `sameLine` body policy set to `fitLine`, a body that cannot
 * render flat (`WrapList.flatLength == -1`: a nested construct holding a
 * block, a `#if`, a `{`-lambda argument) takes the GLUE outcome. Before
 * this slice that outcome was placed WITHOUT any measurement, so the header
 * line grew with the body and could run past `maxLineLength` unbounded.
 * `BodyFit.glueLayout` now owns the answer for all three writer sites that
 * emit such a glue — `BodyFit.fitLineLayout` (case bodies and the plain
 * bare-Ref path), `WriterLowering.buildBodyFitExpr`'s construct-group arm
 * (`ifBody` / `forBody` / `whileBody`) and its single-line-flag arm
 * (`return`-style bodies) — through one `Doc.IfGluedFirstLineExceeds`.
 *
 * THE DECISION IS THREE CONJUNCTS, and each has its own fixture below:
 *
 *  1. Does the glued shape overflow? Measured by the NATURAL first-line
 *     walk (`Renderer.naturalFirstLineWidth`) from the live pen column: a
 *     speculative render that resolves each inner `Group` by its own
 *     `fitsFlat`. The static alternatives were both measured and both fail
 *     — a flat first-line walk counts a condition the renderer WILL wrap
 *     (11 corpus files drifted, most of them regressions), and
 *     `DocMeasure.breakableHead` stops at the first break OPPORTUNITY,
 *     which for a construct-group body is its own `(`.
 *  2. Would breaking FIX it? The same body is re-measured at the column it
 *     would break to, and a body still over-wide there keeps the glue.
 *     Mirrors the fit-gate in `Renderer.collapseParenCommitsOpen`: when the
 *     inner cannot be made a single fitting line, opening does not help.
 *  3. Does the body put anything but its opening delimiter on that line? A
 *     body that breaks right after its own `{` hands the header back two
 *     columns and strands the brace — `Renderer.selfBreakingBraceBody`
 *     records the same verdict for the arrow-body marker.
 *
 * FITS CONVENTION: `<= maxLineLength` on both probes (the `Group` family's,
 * not the strict `<` of the natural-first-line sibling) — this probe is
 * calibrated to a whole rendered LINE, and a line landing exactly on the
 * limit is a line that fits. The fixture below pins all four edges:
 * its glued line is 131 columns and its broken body line 105, so the
 * break window is exactly `maxLineLength` in [105, 130].
 *
 * NOT A SYMMETRY TRIGGER: a glue that this probe turns into a break does
 * NOT make its case siblings break (ω-case-sibling-symmetry's widest-
 * sibling pre-pass consumes bodies through `WrapList.flatLength`, and a
 * glued body answers `-1` there before and after this slice). Pinned below.
 *
 * Per `feedback_unit_test_trivia_writer.md`: the knobs are visible only
 * through `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxGlueWidthSliceTest extends Test {

	/**
	 * A `for` whose body is an `if` statement holding a block — the body's Doc
	 * carries a hardline, so `fitLine` glues it. Anonymised from the reported
	 * site (`TM editor/pitch/PitchArea.hx rePositionBenchPlayers`), preserving
	 * its lengths. Glued, the header line is 131 columns; broken, the body line
	 * is 105.
	 */
	private static final GLUE_SRC: String = 'class M {\n\tfunction f():Void {\n'
		+ '\t\tfor (subItem in listedThings) if (subItem.kind == ItemData.KIND_SUBSTITUTE /*&& cast( subItem, ItemBase ).markedOnDeck*/) {\n'
		+ '\t\t\tsubItem.y = 1;\n\t\t}\n\t}\n}\n';

	/** `GLUE_SRC`'s AST written with the body ALREADY on its own line. */
	private static final GLUE_SRC_BROKEN: String = 'class M {\n\tfunction f():Void {\n\t\tfor (subItem in listedThings)\n'
		+ '\t\t\tif (subItem.kind == ItemData.KIND_SUBSTITUTE /*&& cast( subItem, ItemBase ).markedOnDeck*/) {\n'
		+ '\t\t\t\tsubItem.y = 1;\n\t\t\t}\n\t}\n}\n';

	/**
	 * A glued case body carrying real content before its first break — a call
	 * whose `{`-lambda argument breaks. Glued, the case line is 59 columns;
	 * broken, the body line is 55, so the break window is [55, 58].
	 *
	 * The body must be a VALUE, not a keyword-led statement: since
	 * omega-case-body-controlflow-glue a control-flow body that cannot render
	 * flat is refused the glue outright, so it would never reach the width
	 * question this fixture exists to ask.
	 */
	private static final CASE_GLUE_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n'
		+ '\t\t\tcase 1: listedThings.exists(function(subItem) {\n\t\t\t\treturn subItem.kind == ItemData.KIND_SUBSTITUTE;\n'
		+ '\t\t\t});\n\t\t\tcase _: bar();\n\t\t}\n\t}\n}\n';

	/**
	 * A case body that IS a block: its first line is the bare `{`, and the case
	 * label alone (79 columns) already passes the limits tested with it — the
	 * shape gate 3 refuses.
	 */
	private static final BLOCK_BODY_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n'
		+ '\t\t\tcase ItemKind.KIND_SUBSTITUTE_PLAYER_WITH_A_VERY_LONG_LABEL_INDEED: {\n'
		+ '\t\t\t\tfoo();\n\t\t\t\tbar();\n\t\t\t}\n\t\t}\n\t}\n}\n';

	/**
	 * A `return` whose value carries a `{`-lambda argument — the third glue
	 * emitter. Glued the line is 54 columns, broken 51.
	 */
	private static final RETURN_GLUE_SRC: String = 'class M {\n\tfunction f():Bool {\n'
		+ '\t\treturn listedThings.exists(function(subItem) {\n\t\t\treturn subItem.kind == 1;\n\t\t});\n\t}\n}\n';

	private static final GLUED_LINE: String =
		'\t\tfor (subItem in listedThings) if (subItem.kind == ItemData.KIND_SUBSTITUTE /*&& cast( subItem, ItemBase ).markedOnDeck*/) {';
	private static final BROKEN_LINES: String = '\t\tfor (subItem in listedThings)\n'
		+ '\t\t\tif (subItem.kind == ItemData.KIND_SUBSTITUTE /*&& cast( subItem, ItemBase ).markedOnDeck*/) {';

	public function testOverWideGluedHeaderBreaksTheBody(): Void {
		// The reported symptom: the glued header line is 131 columns against a
		// 130-column limit, and nothing inside the body can shorten it — the
		// condition is a single comparison, so the wrap cascade leaves it whole.
		final out: String = write(GLUE_SRC, fitJson(130));
		Assert.isTrue(out.indexOf(BROKEN_LINES) != -1, 'the over-wide glue must move the body to the next line: <$out>');
		Assert.isTrue(out.indexOf(GLUED_LINE) == -1, 'the glued shape must be gone: <$out>');
	}

	public function testGluedHeaderExactlyAtTheLimitStaysGlued(): Void {
		// Upper edge, `<= n` fits: 131 columns against a 131-column limit is a
		// line that fits, so the pre-slice glue is byte-identical. Discriminates
		// against a `>=`-style probe, which would break here.
		final out: String = write(GLUE_SRC, fitJson(131));
		Assert.isTrue(out.indexOf(GLUED_LINE) != -1, 'a glued line exactly at the limit must stay glued: <$out>');
	}

	public function testBreakIsTakenWhenItJustFixesTheOverflow(): Void {
		// Lower edge of gate 2: the broken body line is 105 columns, so at a
		// 105-column limit the move still resolves the overflow and is taken.
		final out: String = write(GLUE_SRC, fitJson(105));
		Assert.isTrue(out.indexOf(BROKEN_LINES) != -1, 'a break that just fits must be taken: <$out>');
	}

	public function testBreakThatCannotFixTheOverflowKeepsTheGlue(): Void {
		// One column tighter and the body would be over-wide on its own line
		// too (105 > 104). Moving it then buys nothing but an extra line and a
		// deeper indent, so the glue stays — over-wide, exactly as before the
		// slice. This is the gate that keeps the probe off the natural walk's
		// own slop; without it a `return <ternary>` whose rendered line was
		// exactly at the limit broke in the anyparse corpus.
		final out: String = write(GLUE_SRC, fitJson(104));
		Assert.isTrue(out.indexOf(GLUED_LINE) != -1, 'a break that would not fix the overflow must keep the glue: <$out>');
	}

	public function testABodyBreakingAtItsOwnBraceKeepsTheGlue(): Void {
		// Gate 3. The glued line is 81 columns against an 80-column limit, and
		// the body would fit at the broken indent (a lone `{` at 16) — so gates
		// 1 and 2 both say move. Moving buys the header two columns, leaves it
		// over the limit anyway (the label alone is 79), and strands the brace
		// on a line of its own, so the glue is kept instead.
		final out: String = write(BLOCK_BODY_SRC, caseFitJson(80));
		Assert.isTrue(
			out.indexOf('KIND_SUBSTITUTE_PLAYER_WITH_A_VERY_LONG_LABEL_INDEED: {\n') != -1,
			'a body that breaks at its own brace must stay glued: <$out>'
		);
	}

	public function testGlueSurvivesUnderTheNonFitLinePolicies(): Void {
		// Policy inertness: the width answer belongs to `FitLine` alone.
		// `Same` glues unconditionally and must keep doing so at the width that
		// makes `fitLine` break, and `Keep` reproduces the source shape.
		for (policy in ['same', 'keep']) {
			final json: String = '{"wrapping": {"maxLineLength": 130}, "sameLine": {"forBody": "$policy"}}';
			final out: String = write(GLUE_SRC, json);
			Assert.isTrue(out.indexOf(GLUED_LINE) != -1, '`$policy` must keep the unconditional glue: <$out>');
		}
	}

	public function testIsIdempotentAcrossThreePasses(): Void {
		final json: String = fitJson(130);
		final once: String = write(GLUE_SRC, json);
		final twice: String = write(once, json);
		Assert.equals(once, twice, 'the glue-width decision must reach a fixed point in one pass');
		Assert.equals(twice, write(twice, json), 'third pass must also be a fixed point');
	}

	public function testIsIndependentOfTheSourceLineShape(): Void {
		// The decision reads the pen column and the body's Doc, never how the
		// body was written — so the glued source and the already-broken source
		// of ONE AST must render identically.
		final json: String = fitJson(130);
		Assert.equals(write(GLUE_SRC, json), write(GLUE_SRC_BROKEN, json), 'placement must not depend on the source line shape');
		final wide: String = fitJson(131);
		Assert.equals(write(GLUE_SRC, wide), write(GLUE_SRC_BROKEN, wide), 'the same must hold on the glue side of the boundary');
	}

	public function testCaseBodyGlueInheritsTheSameAnswer(): Void {
		// The shared seam: the case-body Star reaches `BodyFit.fitLineLayout`
		// by a different writer path than the `forBody` fixture above, and gets
		// the same width answer without a case-specific rule. The case line is
		// 59 columns glued and the body line 55 broken, so the window is
		// [55, 58] — both edges pinned here.
		final breaks: String = write(CASE_GLUE_SRC, caseFitJson(58));
		Assert.isTrue(
			breaks.indexOf('\t\t\tcase 1:\n\t\t\t\tlistedThings.exists(') != -1, 'an over-wide glued case body must break: <$breaks>'
		);
		final glued: String = write(CASE_GLUE_SRC, caseFitJson(59));
		Assert.isTrue(glued.indexOf('\t\t\tcase 1: listedThings.exists(') != -1, 'a case line exactly at the limit stays glued: <$glued>');
		final tooTight: String = write(CASE_GLUE_SRC, caseFitJson(54));
		Assert.isTrue(
			tooTight.indexOf('\t\t\tcase 1: listedThings.exists(') != -1,
			'below the window the break stops helping and the glue comes back: <$tooTight>'
		);
	}

	public function testReturnBodyGlueInheritsTheSameAnswer(): Void {
		// The third emitter: `buildBodyFitExpr`'s single-line-flag arm, reached
		// by `returnBody` and NOT by either fixture above (the `for` fixture
		// takes the construct-group arm, the `case` one `fitLineLayout`). Same
		// three gates, and it is also the arm whose corpus site motivated gate 2
		// — a `return` whose body would still be over-wide below stays glued.
		// `return` at 2 tabs puts the pen at 14 and the break lands at 12, so
		// the window is only three columns wide: [51, 53].
		final breaks: String = write(RETURN_GLUE_SRC, returnFitJson(53));
		Assert.isTrue(
			breaks.indexOf('\t\treturn\n\t\t\tlistedThings.exists(') != -1, 'an over-wide glued return body must break: <$breaks>'
		);
		final glued: String = write(RETURN_GLUE_SRC, returnFitJson(54));
		Assert.isTrue(glued.indexOf('\t\treturn listedThings.exists(') != -1, 'a return line exactly at the limit stays glued: <$glued>');
		final tooTight: String = write(RETURN_GLUE_SRC, returnFitJson(50));
		Assert.isTrue(
			tooTight.indexOf('\t\treturn listedThings.exists(') != -1,
			'below the window the break stops helping and the glue comes back: <$tooTight>'
		);
	}

	public function testGlueTurnedBreakIsNotASiblingSymmetryTrigger(): Void {
		// ω-case-sibling-symmetry's contract, preserved: a GLUE outcome is not
		// a spread trigger, and turning one into a break must not make it one.
		// `case _: bar();` fits and must stay on its label line even though its
		// sibling just moved down.
		final out: String = write(CASE_GLUE_SRC, caseFitJson(58));
		Assert.isTrue(
			out.indexOf('\t\t\tcase 1:\n\t\t\t\tlistedThings.exists(') != -1, 'the glued sibling must really have broken: <$out>'
		);
		Assert.isTrue(out.indexOf('case _: bar();') != -1, 'a fitting sibling must not be dragged down by a glue-turned-break: <$out>');
	}

	/** `maxLineLength: <w>` with every bare-Ref body knob on `fitLine`. */
	private inline function fitJson(w: Int): String {
		return '{"wrapping": {"maxLineLength": $w}, "sameLine": {"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine"}}';
	}

	private inline function returnFitJson(w: Int): String {
		return '{"wrapping": {"maxLineLength": $w}, "sameLine": {"returnBody": "fitLine"}}';
	}

	private inline function caseFitJson(w: Int): String {
		return '{"wrapping": {"maxLineLength": $w}, "sameLine": {"caseBody": "fitLine", "ifBody": "fitLine"}}';
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
