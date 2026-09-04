package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-comprehension-cuddled-open, if/else body: a comprehension whose BODY is
 * an if/else cuddles its `[` exactly like every other comprehension, and where
 * the body lands below that head is `comprehensionFor`'s question, not the
 * bracket's.
 *
 * S76 had put a `hasTopLevelElse` veto on the cuddle here, reasoning that an
 * `expressionIf: next` if/else body carries a break of its own and would leave
 * the `else` at the CONTAINER line's indent. That is true only while the body is
 * GLUED to the head line, which is what `comprehensionFor: same` (and the old
 * non-strict `fitLine`) does; the veto paid for it by moving the `for` off its
 * `[`, and the user rejected exactly that — three times, on
 * `pony/math/Matrix.hx`. S78 removed the veto and made `fitLine` place the whole
 * body instead of only its first line, so the two levels of the reported
 * expression now agree AND the `else` sits with its own `if`
 * (`testNestedComprehensionsUnderFitLineStaircase`).
 *
 * The `keep` arms below still show the glued body — that is `keep` reading a flat
 * source, not a regression — and they are what proves the cuddle and the body
 * placement are two independent decisions.
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

	/** Same, with `comprehensionFor: same` — tight brackets, generic `arrayWrap` cascade. The cuddle must answer identically. */
	private static final TIGHT_ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "same"}}';

	/** Same as `ON`, with `comprehensionFor: fitLine` — the strict value, which places the BODY below the head. */
	private static final FIT_ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "whitespace": {"bracketConfig": {"comprehensionBrackets": {"openingPolicy": "onlyAfter", "closingPolicy": "before"}}},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** One comprehension whose body is an if/else, written flat on one source line. */
	private static final IF_ELSE_FLAT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue.enabledFlagValue) elementValue.captionValue else '
		+ 'elementValue.detailValue ];\n\t}\n}';

	/** Its layout under `comprehensionFor: keep`: the head cuddles the `[`, the body stays on the head line. */
	private static final IF_ELSE_CUDDLED: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue.enabledFlagValue)\n\t\t\telementValue.captionValue\n\t\telse\n'
		+ '\t\t\telementValue.detailValue\n\t\t];\n\t}\n}';

	/** The same under tight brackets — the cuddle is not a bracket-padding artefact, only the pad after `[` differs. */
	private static final IF_ELSE_CUDDLED_TIGHT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue.enabledFlagValue)\n\t\t\telementValue.captionValue\n\t\telse\n'
		+ '\t\t\telementValue.detailValue\n\t\t];\n\t}\n}';

	/** …and under `comprehensionFor: fitLine`: the head still cuddles, and the `if` head leaves the `for` line. */
	private static final IF_ELSE_FIT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName)\n\t\t\tif (elementValue.enabledFlagValue)\n\t\t\t\telementValue.captionValue\n\t\t\telse\n'
		+ '\t\t\t\telementValue.detailValue\n\t\t];\n\t}\n}';

	/** Two comprehensions, one the body of the other, the inner carrying the if/else — the reported `Matrix.hor` shape. */
	private static final NESTED_FLAT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (rowValue in '
		+ 'sourceMatrixValueName) [ for (indexValue in 0...rowValue.length) if (indexValue > offsetValue) rowValue[indexValue] '
		+ 'else fallbackValue ] ];\n\t}\n}';

	/** Both levels cuddle their own `[` under `keep`, which then leaves both bodies on their head lines. */
	private static final NESTED_CUDDLED: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (rowValue in '
		+ 'sourceMatrixValueName) [ for (indexValue in 0...rowValue.length) if (indexValue > offsetValue)\n'
		+ '\t\t\trowValue[indexValue]\n\t\telse\n\t\t\tfallbackValue\n\t\t]\n\t\t];\n\t}\n}';

	/**
	 * The `Matrix.hor` target under `fitLine`: both `[ for` heads cuddled, each body one level below its own head,
	 * each `]` on its own line at the indent of the line its `[` opened on.
	 */
	private static final NESTED_FIT: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (rowValue in '
		+ 'sourceMatrixValueName)\n\t\t\t[ for (indexValue in 0...rowValue.length)\n\t\t\t\tif (indexValue > offsetValue)\n'
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

	/** An if/else body cuddles like any other: the `for` head is glued to its own `[`. */
	@:pin('control')
	@:killer('M-ELSE-GATE')
	public function testIfElseBodyCuddles(): Void {
		Assert.equals(IF_ELSE_CUDDLED, HxWriteFixture.triviaWrite(IF_ELSE_FLAT, ON));
	}

	/** The same answer under tight comprehension brackets — the cuddle is not a bracket-padding artefact. */
	@:pin('control')
	@:killer('M-ELSE-GATE')
	public function testIfElseBodyCuddlesWithTightBrackets(): Void {
		Assert.equals(IF_ELSE_CUDDLED_TIGHT, HxWriteFixture.triviaWrite(IF_ELSE_FLAT, TIGHT_ON));
	}

	/** Under `fitLine` the cuddle stands AND the `if` head leaves the `for` line — the two halves are independent. */
	@:pin('control')
	@:killer('M-FIRST-LINE-FIT')
	public function testIfElseBodyUnderFitLineLeavesTheHeadLine(): Void {
		Assert.equals(IF_ELSE_FIT, HxWriteFixture.triviaWrite(IF_ELSE_FLAT, FIT_ON));
	}

	/** Nested comprehensions in ONE expression choose the SAME layout — both cuddled. */
	@:pin('control')
	@:killer('M-ELSE-GATE')
	public function testNestedComprehensionsChooseTheSameLayout(): Void {
		Assert.equals(NESTED_CUDDLED, HxWriteFixture.triviaWrite(NESTED_FLAT, ON));
	}

	/** The `Matrix.hor` shape under `fitLine` — the layout the user asked for, from a flat source. */
	@:pin('control')
	@:killer('M-FIRST-LINE-FIT')
	public function testNestedComprehensionsUnderFitLineStaircase(): Void {
		Assert.equals(NESTED_FIT, HxWriteFixture.triviaWrite(NESTED_FLAT, FIT_ON));
	}

	/** The `fitLine` layout is a fixed point — no oscillation between writes. */
	public function testFitLineLayoutIsIdempotent(): Void {
		Assert.equals(NESTED_FIT, HxWriteFixture.triviaWrite(NESTED_FIT, FIT_ON));
	}

	/** VACUITY GUARD: a filter `if` with no `else` still cuddles, so an arm that kills the cuddle outright fails here. */
	@:pin('control')
	@:killer('M-CUDDLE-OFF')
	public function testFilterIfWithoutElseStillCuddles(): Void {
		Assert.equals(FILTER_CUDDLED, HxWriteFixture.triviaWrite(FILTER_FLAT, ON));
	}

}
