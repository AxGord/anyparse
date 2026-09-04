package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * ω-comprehension-cuddled-open, if/else body: a comprehension whose BODY is
 * an `expressionIf: next` if/else already carries a leading break of its own,
 * so the cuddled-open shape must decline it — `isCuddleableComprehensionItem`
 * asks `hasTopLevelElse`, the same question the arrow path asks through
 * `arrowBodyIsBrokenIfElse`.
 *
 * Before that gate, cuddling glued `[`, the `for` head and the `if` condition
 * into ONE line and left the `else` at the CONTAINER line's indent, so the
 * `else` read as belonging to whatever opened that line. Nested one
 * comprehension inside another, the OUTER was separately vetoed by the
 * nested-generator gate and took the leading-break shape, so a single
 * expression showed TWO layouts for one construct — the user-reported defect
 * on `pony/math/Matrix.hx` (2026-09-04).
 *
 * A FILTER `if` (no `else`) is untouched: `testFilterIfWithoutElseStillCuddles`
 * is the knob's own canonical shape and is the vacuity guard for this class —
 * it is GREEN on the base binary, so an arm that kills the cuddle outright
 * (rather than only for if/else bodies) fails it.
 */
@:nullSafety(Strict)
final class HxComprehensionIfElseBodySliceTest extends Test {

	/** Project-shaped config with the knob ON and padded comprehension brackets (`whitespace.bracketConfig`). */
	private static final ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "whitespace": {"bracketConfig": {"comprehensionBrackets": {"openingPolicy": "onlyAfter", "closingPolicy": "before"}}},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "keep"}}';

	/** Same, with `comprehensionFor: same` — tight brackets, generic `arrayWrap` cascade. The gate must answer identically. */
	private static final TIGHT_ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "same"}}';

	/** One comprehension whose body is an if/else, written flat on one source line. */
	private static final IF_ELSE_FLAT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue.enabledFlagValue) elementValue.captionValue else '
		+ 'elementValue.detailValue ];\n\t}\n}';

	/** Its layout: the `[` leads-breaks, the head sits one level in, the `else` aligns with its own `for`. */
	private static final IF_ELSE_BROKEN: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tfor (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue.enabledFlagValue)\n\t\t\t\telementValue.captionValue\n\t\t\telse\n'
		+ '\t\t\t\telementValue.detailValue\n\t\t];\n\t}\n}';

	/** Two comprehensions, one the body of the other, the inner carrying the if/else — the reported `Matrix.hor` shape. */
	private static final NESTED_FLAT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (rowValue in '
		+ 'sourceMatrixValueName) [ for (indexValue in 0...rowValue.length) if (indexValue > offsetValue) rowValue[indexValue] '
		+ 'else fallbackValue ] ];\n\t}\n}';

	/** Both levels lead-break after their own `[` — one construct, one layout. */
	private static final NESTED_BROKEN: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tfor (rowValue in '
		+ 'sourceMatrixValueName) [\n\t\t\t\tfor (indexValue in 0...rowValue.length) if (indexValue > offsetValue)\n'
		+ '\t\t\t\t\trowValue[indexValue]\n\t\t\t\telse\n\t\t\t\t\tfallbackValue\n\t\t\t]\n\t\t];\n\t}\n}';

	/** A FILTER `if` (no `else`) over a multi-line object literal — the knob's canonical input. */
	private static final FILTER_FLAT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue.enabledFlagValue) ({ captionValue: elementValue.captionValue, '
		+ 'detailValue: elementValue.detailValue, extraValue: elementValue.extraDescriptorValue, orderValue: '
		+ 'elementValue.orderingIndexValue }) ];\n\t}\n}';

	/** …and its cuddled layout, unchanged by this slice. */
	private static final FILTER_CUDDLED: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue.enabledFlagValue) ({\n\t\t\tcaptionValue: elementValue.captionValue,\n'
		+ '\t\t\tdetailValue: elementValue.detailValue,\n\t\t\textraValue: elementValue.extraDescriptorValue,\n'
		+ '\t\t\torderValue: elementValue.orderingIndexValue\n\t\t})\n\t\t];\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** An if/else body declines the cuddle: the `[` leads-breaks and the `else` lands at its own `for`'s indent. */
	@:pin('control')
	@:killer('M-ELSE-GATE')
	public function testIfElseBodyDeclinesTheCuddle(): Void {
		Assert.equals(IF_ELSE_BROKEN, HxWriteFixture.triviaWrite(IF_ELSE_FLAT, ON));
	}

	/** The same answer under tight comprehension brackets — the gate is not a bracket-padding artefact. */
	@:pin('control')
	@:killer('M-ELSE-GATE')
	public function testIfElseBodyDeclinesTheCuddleWithTightBrackets(): Void {
		Assert.equals(IF_ELSE_BROKEN, HxWriteFixture.triviaWrite(IF_ELSE_FLAT, TIGHT_ON));
	}

	/** Nested comprehensions in ONE expression choose the SAME layout — the reported defect. */
	@:pin('control')
	@:killer('M-ELSE-GATE')
	public function testNestedComprehensionsChooseTheSameLayout(): Void {
		Assert.equals(NESTED_BROKEN, HxWriteFixture.triviaWrite(NESTED_FLAT, ON));
	}

	/** The declined layout is a fixed point — no oscillation between writes. */
	public function testDeclinedLayoutIsIdempotent(): Void {
		Assert.equals(NESTED_BROKEN, HxWriteFixture.triviaWrite(NESTED_BROKEN, ON));
	}

	/** VACUITY GUARD: a filter `if` with no `else` still cuddles, so an arm that kills the cuddle outright fails here. */
	@:pin('control')
	@:killer('M-CUDDLE-OFF')
	public function testFilterIfWithoutElseStillCuddles(): Void {
		Assert.equals(FILTER_CUDDLED, HxWriteFixture.triviaWrite(FILTER_FLAT, ON));
	}

}
