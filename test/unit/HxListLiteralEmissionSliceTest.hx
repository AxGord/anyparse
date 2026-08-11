package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.ArrayMatrixWrap;
import anyparse.format.TrailingCommaPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Wrapped list-literal emission — the three TM-driven policies that share
 * the sep-Star break-mode layout. Two are new here; `arrayMatrixWrap` is
 * pre-existing and covered because the three land together in TM's config
 * and only their combination reproduces the shipped shapes.
 *
 * 1. `emptyLines.uniformStatementBlanks: collapse` extended to
 * ARRAY-LITERAL element gaps. Same rule as the statement-block policy: when
 * EVERY interior gap between adjacent elements is blank the blanks carry no
 * grouping information and are stripped; a selective mix — or a leading
 * comment on any element — leaves the literal byte-exact. A collapsed gap
 * also drops its hardline requirement, so the literal re-flows exactly as
 * the same source without the blanks would (pinned under a `noWrap` array
 * cascade, where the two routes visibly diverge).
 * 2. `wrapping.trailingComma: remove` — a MULTILINE array literal, object
 * literal or argument list never ends with a separator, and `remove`
 * outranks the `trailingCommas.*Default` ADD knobs. Default `keep`
 * round-trips the source comma. Flat lists and constructs whose trailing
 * separator is mandatory (`{ > Base, }`) are out of scope, as are function
 * parameter lists.
 * 3. `wrapping.arrayMatrixWrap: matrixWrapNoAlign` — a source matrix grid
 * keeps its row grouping but drops the column padding, so every row indents
 * with plain tabs and every comma is followed by exactly one space.
 *
 * Options come from `HaxeFormatConfigLoader.loadHxFormatJson` on the
 * load-bearing subset of TM's own `hxformat.json` (tab indent, 140 columns,
 * `commaPolicy: after`) — a defaults-only probe would be config-blind to
 * the wrap cascade these shapes hit.
 */
@:nullSafety(Strict)
class HxListLiteralEmissionSliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	/** TM's load-bearing formatting keys, with all three policies off. */
	private static final BASE_JSON: String =
		'{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140},"whitespace":{"commaPolicy":"after"}}';

	/** Same, with `uniformStatementBlanks: collapse` (TM's own setting). */
	private static final COLLAPSE_JSON: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140},'
		+ '"whitespace":{"commaPolicy":"after"},"emptyLines":{"uniformStatementBlanks":"collapse"}}';

	/** Same, with `wrapping.trailingComma: remove`. */
	private static final REMOVE_JSON: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"trailingComma":"remove"},"whitespace":{"commaPolicy":"after"}}';

	/** Same, with `wrapping.arrayMatrixWrap: matrixWrapNoAlign`. */
	private static final NO_ALIGN_JSON: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"arrayMatrixWrap":"matrixWrapNoAlign"},"whitespace":{"commaPolicy":"after"}}';

	/**
	 * `collapse` plus a pure-`noWrap` array cascade — the config where the
	 * dropped hardline requirement is OBSERVABLE: collapsing the gaps lets
	 * the literal flatten, which is the shape a blank-free source produces.
	 */
	private static final COLLAPSE_NOWRAP_JSON: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"arrayWrap":{"defaultWrap":"noWrap","rules":[]}},'
		+ '"whitespace":{"commaPolicy":"after"},"emptyLines":{"uniformStatementBlanks":"collapse"}}';

	/** `wrapping.trailingComma: remove` plus the `trailingCommas` ADD knobs on. */
	private static final REMOVE_OVER_ADD_JSON: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"trailingComma":"remove"},"whitespace":{"commaPolicy":"after"},'
		+ '"trailingCommas":{"arrayLiteralDefault":"yes","callArgumentDefault":"yes","objectLiteralDefault":"yes"}}';

	/** Same ADD knobs, `wrapping.trailingComma` absent — the `keep` baseline. */
	private static final ADD_JSON: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140},"whitespace":{"commaPolicy":"after"},'
		+ '"trailingCommas":{"arrayLiteralDefault":"yes","callArgumentDefault":"yes","objectLiteralDefault":"yes"}}';

	// --- item (a): array-literal uniform element blanks ---
	// TM `TextAreaFormGroup.createCustomLabel` shape: two elements, one gap, blank.
	private static final ARR_TWO: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\n\t\t\tbeta\n\t\t];\n\t}\n}\n';

	// Three elements, BOTH interior gaps blank — uniform.
	private static final ARR_UNIFORM: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\n\t\t\tbeta,\n\n\t\t\tgamma\n\t\t];\n\t}\n}\n';

	// Three elements, only the FIRST gap blank — selective, deliberate grouping.
	private static final ARR_SELECTIVE: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\n\t\t\tbeta,\n\t\t\tgamma\n\t\t];\n\t}\n}\n';

	// Uniform gaps but a `//` header on an element — grouping intent unclear.
	private static final ARR_COMMENT: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\n\t\t\t// header\n\t\t\tbeta\n\t\t];\n\t}\n}\n';

	// Edge blank right after `[` plus a uniform interior gap.
	private static final ARR_EDGE_OPEN: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [\n\n\t\t\talpha,\n\n\t\t\tbeta\n\t\t];\n\t}\n}\n';

	// Uniform interior gap plus an edge blank before `]`.
	private static final ARR_EDGE_CLOSE: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\n\t\t\tbeta\n\n\t\t];\n\t}\n}\n';

	// Object literal with a uniform gap — NOT opted into the policy.
	private static final OBJ_TWO: String = 'class C {\n\tfunction f() {\n\t\tvar o = {\n\t\t\talpha: 1,\n\n\t\t\tbeta: 2\n\t\t};\n\t}\n}\n';

	// --- item (b): multiline trailing comma ---

	private static final ARR_TRAIL: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\t\t\tbeta,\n\t\t];\n\t}\n}\n';
	private static final OBJ_TRAIL: String =
		'class C {\n\tfunction f() {\n\t\tvar o = {\n\t\t\talpha: 1,\n\t\t\tbeta: 2,\n\t\t};\n\t}\n}\n';
	private static final NEW_TRAIL: String = 'class C {\n\tfunction f() {\n\t\tvar n = new T(\n\t\t\talphaAlphaAlphaAlphaAlpha,\n'
		+ '\t\t\tbetaBetaBetaBetaBetaBeta,\n\t\t\tgammaGammaGammaGammaGamma,\n\t\t\tdeltaDeltaDeltaDeltaDelta,\n'
		+ '\t\t\tepsilonEpsilonEpsilonEps,\n\t\t);\n\t}\n}\n';
	private static final ARR_FLAT_TRAIL: String = 'class C {\n\tfunction f() {\n\t\tvar a = [alpha, beta,];\n\t}\n}\n';
	private static final ANON_EXTENSION: String = 'typedef E = {\n\t> Base,\n}\n';
	private static final PARAMS_TRAIL: String = 'class C {\n\tfunction f(\n\t\talphaAlphaAlphaAlphaAlpha: Int,\n'
		+ '\t\tbetaBetaBetaBetaBetaBeta: Int,\n\t\tgammaGammaGammaGammaGamma: Int,\n\t\tdeltaDeltaDeltaDeltaDelta: Int,\n'
		+ '\t\tepsilonEpsilonEpsilonEps: Int,\n\t): Void {}\n}\n';
	private static final CALL_TRAIL: String = 'class C {\n\tfunction f() {\n\t\tg(\n\t\t\talphaAlphaAlphaAlphaAlpha,\n'
		+ '\t\t\tbetaBetaBetaBetaBetaBeta,\n\t\t\tgammaGammaGammaGammaGamma,\n\t\t\tdeltaDeltaDeltaDeltaDelta,\n'
		+ '\t\t\tepsilonEpsilonEpsilonEps,\n\t\t);\n\t}\n}\n';

	/** Uniform gaps under a `noWrap` array cascade — no source trailing comma. */
	private static final ARR_NOWRAP: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\n\t\t\tbeta,\n\n\t\t\tgamma\n\t\t];\n\t}\n}\n';

	/** No source trailing comma anywhere — the ADD-knob path. */
	private static final ARR_NO_TRAIL: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talphaAlphaAlphaAlpha,\n'
		+ '\t\t\tbetaBetaBetaBetaBeta,\n\t\t\tgamma\n\t\t];\n\t}\n}\n';

	// --- item (c): matrix rows ---
	// TM `PitchArea.mouseDownLinePen` shape: 3 rows of 2, ragged cell widths.
	private static final MATRIX: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\tSTRAIGHT_LINE, STRAIGHT_LINE_DASHED,\n'
		+ '\t\t\tARC_LINE, ARC_LINE_DASHED,\n\t\t\tWAVE_LINE, WAVE_LINE_DASHED\n\t\t];\n\t}\n}\n';

	// --- config plumbing ---

	public inline function testTrailingCommaDefaultsToKeep(): Void {
		Assert.equals(TrailingCommaPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.trailingComma);
	}

	public function testRemoveDropsMultilineCallArgTrailingComma(): Void {
		// A plain call has no source-trailing-comma slot, so the ADD knob is
		// the only way its broken arg list can end with a `,` at all.
		Assert.isTrue(addKnob(CALL_TRAIL).indexOf('epsilonEpsilonEpsilonEps,') >= 0, addKnob(CALL_TRAIL));
		Assert.isTrue(removeOverAdd(CALL_TRAIL).indexOf('epsilonEpsilonEpsilonEps,') < 0, removeOverAdd(CALL_TRAIL));
	}

	public function testRemoveOutranksTheAddKnob(): Void {
		Assert.isTrue(addKnob(ARR_NO_TRAIL).indexOf('gamma,\n\t\t]') >= 0, addKnob(ARR_NO_TRAIL));
		Assert.isTrue(removeOverAdd(ARR_NO_TRAIL).indexOf('gamma\n\t\t]') >= 0, removeOverAdd(ARR_NO_TRAIL));
	}

	public function testRemoveIsIdempotent(): Void {
		Assert.equals(remove(ARR_TRAIL), remove(remove(ARR_TRAIL)));
		Assert.equals(remove(OBJ_TRAIL), remove(remove(OBJ_TRAIL)));
		Assert.equals(remove(NEW_TRAIL), remove(remove(NEW_TRAIL)));
		Assert.equals(remove(CALL_TRAIL), remove(remove(CALL_TRAIL)));
	}

	public function testCollapseIsIdempotent(): Void {
		Assert.equals(collapse(ARR_TWO), collapse(collapse(ARR_TWO)));
		Assert.equals(collapse(ARR_UNIFORM), collapse(collapse(ARR_UNIFORM)));
		Assert.equals(collapse(ARR_EDGE_OPEN), collapse(collapse(ARR_EDGE_OPEN)));
		Assert.equals(collapse(ARR_EDGE_CLOSE), collapse(collapse(ARR_EDGE_CLOSE)));
	}

	/**
	 * The collapsed gap must ALSO drop its hardline requirement, so the
	 * literal re-flows exactly as the blank-free source does. Under a
	 * `noWrap` array cascade the two routes diverge visibly: with the
	 * hardline still standing the list would stay one-element-per-line and
	 * the next pass would flatten it, i.e. not be idempotent.
	 */
	public function testCollapsedGapReflowsLikeABlankFreeSource(): Void {
		final blankFree: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\t\t\tbeta,\n\t\t\tgamma\n\t\t];\n\t}\n}\n';
		Assert.equals(write(blankFree, COLLAPSE_NOWRAP_JSON), write(ARR_NOWRAP, COLLAPSE_NOWRAP_JSON));
		Assert.equals(write(ARR_NOWRAP, COLLAPSE_NOWRAP_JSON), write(write(ARR_NOWRAP, COLLAPSE_NOWRAP_JSON), COLLAPSE_NOWRAP_JSON));
	}

	public function testConfigTrailingCommaRemoveParsed(): Void {
		Assert.equals(TrailingCommaPolicy.Remove, opts('{"wrapping":{"trailingComma":"remove"}}').trailingComma);
	}

	public function testConfigTrailingCommaKeepParsed(): Void {
		Assert.equals(TrailingCommaPolicy.Keep, opts('{"wrapping":{"trailingComma":"keep"}}').trailingComma);
	}

	public function testConfigTrailingCommaOmittedDefaultsKeep(): Void {
		Assert.equals(TrailingCommaPolicy.Keep, opts('{}').trailingComma);
	}

	// --- item (a) ---

	public function testArrayTwoElementUniformGapCollapses(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\t\t\tbeta\n\t\t];\n\t}\n}\n';
		Assert.equals(expected, collapse(ARR_TWO));
	}

	public function testArrayAllGapsBlankCollapse(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\t\t\tbeta,\n\t\t\tgamma\n\t\t];\n\t}\n}\n';
		Assert.equals(expected, collapse(ARR_UNIFORM));
	}

	public function testArraySelectiveGapsStayByteExact(): Void {
		Assert.equals(base(ARR_SELECTIVE), collapse(ARR_SELECTIVE));
		Assert.isTrue(collapse(ARR_SELECTIVE).indexOf('alpha,\n\n\t\t\tbeta,\n\t\t\tgamma') >= 0);
	}

	public function testArrayElementLeadingCommentBails(): Void {
		Assert.equals(base(ARR_COMMENT), collapse(ARR_COMMENT));
		Assert.isTrue(collapse(ARR_COMMENT).indexOf('alpha,\n\n\t\t\t// header') >= 0);
	}

	public function testArrayEdgeBlankAfterOpenBracketIsNotAGap(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\t\t\tbeta\n\t\t];\n\t}\n}\n';
		Assert.equals(expected, collapse(ARR_EDGE_OPEN));
	}

	public function testArrayEdgeBlankBeforeCloseBracketIsNotAGap(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\t\t\tbeta\n\t\t];\n\t}\n}\n';
		Assert.equals(expected, collapse(ARR_EDGE_CLOSE));
	}

	public function testKnobKeepLeavesArrayBlanksIntact(): Void {
		Assert.notEquals(collapse(ARR_TWO), base(ARR_TWO));
		Assert.isTrue(base(ARR_TWO).indexOf('alpha,\n\n\t\t\tbeta') >= 0);
	}

	public function testObjectLiteralGapsAreNotCollapsed(): Void {
		Assert.equals(base(OBJ_TWO), collapse(OBJ_TWO));
		Assert.isTrue(collapse(OBJ_TWO).indexOf('alpha: 1,\n\n\t\t\tbeta: 2') >= 0);
	}

	// --- item (b) ---

	public function testDefaultKeepsMultilineArrayTrailingComma(): Void {
		Assert.isTrue(base(ARR_TRAIL).indexOf('beta,\n\t\t]') >= 0, base(ARR_TRAIL));
	}

	public function testRemoveDropsMultilineArrayTrailingComma(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\talpha,\n\t\t\tbeta\n\t\t];\n\t}\n}\n';
		Assert.equals(expected, remove(ARR_TRAIL));
	}

	public function testRemoveDropsMultilineObjectLiteralTrailingComma(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar o = {\n\t\t\talpha: 1,\n\t\t\tbeta: 2\n\t\t};\n\t}\n}\n';
		Assert.equals(expected, remove(OBJ_TRAIL));
	}

	public function testRemoveDropsMultilineNewArgsTrailingComma(): Void {
		Assert.isTrue(base(NEW_TRAIL).indexOf('epsilonEpsilonEpsilonEps,);') >= 0, base(NEW_TRAIL));
		Assert.isTrue(remove(NEW_TRAIL).indexOf('epsilonEpsilonEpsilonEps);') >= 0, remove(NEW_TRAIL));
	}

	public function testRemoveLeavesFlatArrayTrailingComma(): Void {
		Assert.equals(base(ARR_FLAT_TRAIL), remove(ARR_FLAT_TRAIL));
		Assert.isTrue(remove(ARR_FLAT_TRAIL).indexOf('[alpha, beta,]') >= 0);
	}

	public function testRemoveLeavesMandatoryAnonExtensionComma(): Void {
		Assert.equals(base(ANON_EXTENSION), remove(ANON_EXTENSION));
		Assert.isTrue(remove(ANON_EXTENSION).indexOf('> Base,') >= 0);
	}

	public function testRemoveLeavesFunctionParamTrailingComma(): Void {
		Assert.isTrue(base(PARAMS_TRAIL).indexOf('epsilonEpsilonEpsilonEps:Int,)') >= 0, base(PARAMS_TRAIL));
		Assert.equals(base(PARAMS_TRAIL), remove(PARAMS_TRAIL));
	}

	// --- item (c) ---

	public function testMatrixWithAlignIsTheDefault(): Void {
		Assert.equals(ArrayMatrixWrap.MatrixWrapWithAlign, HaxeFormat.instance.defaultWriteOptions.arrayMatrixWrap);
		Assert.isTrue(base(MATRIX).indexOf('\t\t\t     ARC_LINE,      ARC_LINE_DASHED,') >= 0, base(MATRIX));
	}

	public function testNoAlignNormalizesRowWhitespaceKeepingGrouping(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\tSTRAIGHT_LINE, STRAIGHT_LINE_DASHED,\n'
			+ '\t\t\tARC_LINE, ARC_LINE_DASHED,\n\t\t\tWAVE_LINE, WAVE_LINE_DASHED\n\t\t];\n\t}\n}\n';
		Assert.equals(expected, noAlign(MATRIX));
	}

	private static inline function collapse(source: String): String {
		return write(source, COLLAPSE_JSON);
	}

	private static inline function noAlign(source: String): String {
		return write(source, NO_ALIGN_JSON);
	}

	private static inline function addKnob(source: String): String {
		return write(source, ADD_JSON);
	}

	private static inline function removeOverAdd(source: String): String {
		return write(source, REMOVE_OVER_ADD_JSON);
	}

	// --- helpers ---

	private static function opts(json: String): HxModuleWriteOptions {
		return HaxeFormatConfigLoader.loadHxFormatJson(json);
	}

	private static function write(source: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts(json));
	}

	private static function base(source: String): String {
		return write(source, BASE_JSON);
	}

	private static function remove(source: String): String {
		return write(source, REMOVE_JSON);
	}

}
