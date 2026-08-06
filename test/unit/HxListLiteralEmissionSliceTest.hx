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
 * the sep-Star break-mode layout:
 *
 * 1. `emptyLines.uniformStatementBlanks: collapse` extended to ARRAY-LITERAL
 * element gaps. Same rule as the statement-block policy: when EVERY interior
 * gap between adjacent elements is blank the blanks carry no grouping
 * information and are stripped; a selective mix — or a leading comment on any
 * element — leaves the literal byte-exact.
 * 2. `wrapping.trailingComma: remove` — a MULTILINE array literal / object
 * literal / `new` argument list never ends with a separator. Default `keep`
 * round-trips the source comma. Flat lists and constructs whose trailing
 * separator is mandatory (`{ > Base, }`) are out of scope.
 * 3. `wrapping.arrayMatrixWrap: matrixWrapNoAlign` — a source matrix grid
 * keeps its row grouping but drops the column padding, so every row indents
 * with plain tabs and every comma is followed by exactly one space.
 *
 * Options come from `HaxeFormatConfigLoader.loadHxFormatJson` on the
 * load-bearing subset of TM's own `hxformat.json` (tab indent, 140 columns,
 * `commaPolicy: after`) — a defaults-only probe would be config-blind to the
 * wrap cascade these shapes hit.
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

	private static final PARAMS_TRAIL: String = 'class C {\n\tfunction f(\n\t\talpha: Int,\n\t\tbeta: Int,\n\t): Void {}\n}\n';

	// --- item (c): matrix rows ---
	// TM `PitchArea.mouseDownLinePen` shape: 3 rows of 2, ragged cell widths.
	private static final MATRIX: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\tSTRAIGHT_LINE, STRAIGHT_LINE_DASHED,\n'
		+ '\t\t\tARC_LINE, ARC_LINE_DASHED,\n\t\t\tWAVE_LINE, WAVE_LINE_DASHED\n\t\t];\n\t}\n}\n';

	// --- config plumbing ---

	public function testTrailingCommaDefaultsToKeep(): Void {
		Assert.equals(TrailingCommaPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.trailingComma);
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

	// --- helpers ---

	private static function opts(json: String): HxModuleWriteOptions {
		return HaxeFormatConfigLoader.loadHxFormatJson(json);
	}

	private static function write(source: String, json: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast, opts(json));
	}

	private static function base(source: String): String {
		return write(source, BASE_JSON);
	}

	private static function collapse(source: String): String {
		return write(source, COLLAPSE_JSON);
	}

	private static function remove(source: String): String {
		return write(source, REMOVE_JSON);
	}

	private static function noAlign(source: String): String {
		return write(source, NO_ALIGN_JSON);
	}

}
