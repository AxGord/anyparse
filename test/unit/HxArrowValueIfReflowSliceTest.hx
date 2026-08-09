package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-arrow-value-if-reflow scope: `sameLine.expressionIfArrowBodyReflow:
 * true` makes a value-`if`/`else` chain in an arrow-lambda body one
 * width-decided unit - flat when it fits at its column, one arm per line with
 * each branch value glued to its own condition when it does not. Every other
 * value-`if` (var-init, call-arg, statement position), the ternary form, a
 * block arrow body and an else-less arrow-body `if` keep the `expressionIf`
 * cascade's answer.
 *
 * Both source shapes are pinned for every outcome: the writer must reach the
 * same result from the flat source AND from the already-wrapped one, which is
 * what the source-multiline keep floor would otherwise break (a fix validated
 * only on flat input is a no-op on the real wrapped file).
 *
 * The comment refusal is pinned at FOUR positions along one chain, because it
 * has to hold in both directions: a member sees comments below it through the
 * `else`-spine walk, and comments above it through `_arrowValueIfBlocked` on
 * the branch descent. With either half missing the chain rendered half
 * re-flowed and half in policy shape, so a single-position fixture proves
 * nothing - each of the four must equal the knob-off output byte for byte.
 *
 * Config `expressionIf: "next"` + `ifBody: "fitLine"` reproduces the reported
 * setup: without the knob every branch value drops below its condition and
 * the `else` arms sit at the OUTER indent, even when the whole statement fits.
 */
@:nullSafety(Strict)
final class HxArrowValueIfReflowSliceTest extends Test {

	private static final CONFIG_ON: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"expressionIf": "next", "ifBody": "fitLine", "expressionIfArrowBodyReflow": true}}';
	private static final CONFIG_OFF: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"expressionIf": "next", "ifBody": "fitLine"}}';

	/** Padded object-literal braces, for the refusal's effect on a SIBLING knob. */
	private static final CONFIG_OBJECT_ON: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"expressionIf": "next", "ifBody": "fitLine", "expressionIfArrowBodyReflow": true}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "around", "closingPolicy": "around", "arrowBodyReflow": true}}}}';

	private static final CONFIG_OBJECT_OFF: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"expressionIf": "next", "ifBody": "fitLine"}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "around", "closingPolicy": "around", "arrowBodyReflow": true}}}}';

	/** `ifBody: "next"` - the only setting under which the no-else gate is visible. */
	private static final CONFIG_NEXT_ON: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"expressionIf": "next", "ifBody": "next", "expressionIfArrowBodyReflow": true}}';

	private static final CONFIG_NEXT_OFF: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"expressionIf": "next", "ifBody": "next"}}';
	private static final FLAT_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titems.rank((p:Item, q:Item) -> if (p.orderKeyVal < q.orderKeyVal) -1 else if (p.orderKeyVal > q.orderKeyVal) 1 else 0);\n'
		+ '\t}\n}';
	private static final FLAT_KEPT: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titems.rank((p:Item, q:Item) -> if (p.orderKeyVal < q.orderKeyVal)\n\t\t\t-1\n'
		+ '\t\telse if (p.orderKeyVal > q.orderKeyVal)\n\t\t\t1\n\t\telse\n\t\t\t0);\n\t}\n}';
	private static final WIDE_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titemCollection.rankEntries((primaryEntry:ItemEntry, secondaryEntry:ItemEntry) -> if (primaryEntry.orderKeyValue < secondaryEntry.orderKeyValue) -1 else if (primaryEntry.orderKeyValue > secondaryEntry.orderKeyValue) 1 else 0);\n'
		+ '\t}\n}';
	private static final WIDE_REFLOWED: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titemCollection.rankEntries((primaryEntry:ItemEntry, secondaryEntry:ItemEntry) ->\n'
		+ '\t\t\tif (primaryEntry.orderKeyValue < secondaryEntry.orderKeyValue) -1\n'
		+ '\t\t\telse if (primaryEntry.orderKeyValue > secondaryEntry.orderKeyValue) 1\n\t\t\telse 0\n\t\t);\n' + '\t}\n}';
	private static final WIDE_KEPT: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titemCollection.rankEntries((primaryEntry:ItemEntry, secondaryEntry:ItemEntry) ->\n'
		+ '\t\t\tif (primaryEntry.orderKeyValue < secondaryEntry.orderKeyValue)\n\t\t\t\t-1\n'
		+ '\t\t\telse if (primaryEntry.orderKeyValue > secondaryEntry.orderKeyValue)\n\t\t\t\t1\n\t\t\telse\n'
		+ '\t\t\t\t0\n\t\t);\n\t}\n}';
	private static final MID_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titemCollection.rankEntries((primary:ItemEntry, secondary:ItemEntry) -> if (primary.orderKeyValue < secondary.orderKeyValue) -1 else if (primary.orderKeyValue > secondary.orderKeyValue) 1 else 0);\n'
		+ '\t}\n}';
	private static final MID_REFLOWED: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titemCollection.rankEntries((primary:ItemEntry, secondary:ItemEntry) ->\n'
		+ '\t\t\tif (primary.orderKeyValue < secondary.orderKeyValue) -1 else if (primary.orderKeyValue > secondary.orderKeyValue) 1 else 0\n'
		+ '\t\t);\n\t}\n}';
	private static final COMMENT_OUTER_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titems.rank((p:Item, q:Item) -> if (p.orderKeyVal < q.orderKeyVal)\n'
		+ '\t\t\t// ascending\n\t\t\t-1\n\t\telse if (p.orderKeyVal > q.orderKeyVal)\n\t\t\t1\n' + '\t\telse\n\t\t\t0);\n\t}\n}';
	private static final COMMENT_INNER_COND_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titems.rank((p:Item, q:Item) -> if (p.orderKeyVal < q.orderKeyVal)\n\t\t\t-1\n'
		+ '\t\telse if (p.orderKeyVal > q.orderKeyVal) // descending\n\t\t\t1\n\t\telse\n\t\t\t0);\n\t}\n}';
	private static final COMMENT_INNER_VALUE_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titems.rank((p:Item, q:Item) -> if (p.orderKeyVal < q.orderKeyVal)\n\t\t\t-1\n'
		+ '\t\telse if (p.orderKeyVal > q.orderKeyVal)\n\t\t\t// descending\n\t\t\t1\n\t\telse\n' + '\t\t\t0);\n\t}\n}';
	private static final COMMENT_TAIL_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titems.rank((p:Item, q:Item) -> if (p.orderKeyVal < q.orderKeyVal)\n\t\t\t-1\n'
		+ '\t\telse if (p.orderKeyVal > q.orderKeyVal)\n\t\t\t1\n\t\telse\n\t\t\t// equal\n\t\t\t0);\n\t}\n}';

	/**
	 * The trailing comment sits after the chain's LAST value, which is the one
	 * position no field of the `if` node owns - the slot belongs to the
	 * enclosing call's argument element.
	 */
	private static final TRAIL_ON_TAIL_VALUE_SRC: String = 'class C {\n\tfunction test() {\n'
		+ '\t\titems.rank((p:Item, q:Item) -> if (p.orderKeyVal < q.orderKeyVal)\n\t\t\t-1\n'
		+ '\t\telse if (p.orderKeyVal > q.orderKeyVal)\n\t\t\t1\n\t\telse\n\t\t\t0 // equal\n\t\t);\n' + '\t}\n}';

	/** Same slot, two-arm chain - the reported `APIRequest2` shape. */
	private static final TRAIL_ON_ELSE_VALUE_SRC: String = 'class C {\n\tfunction test() {\n\t\tAPIToken.instance.waitToken(success ->\n'
		+ '\t\t\tif (success)\n\t\t\t\tdoRequest();\n\t\t\telse\n' + '\t\t\t\ttokenError() // Call error handlers\n\t\t);\n\t}\n}';

	private static final BLOCK_SRC: String =
		'class C {\n\tfunction test() {\n\t\titems.rank((p:Item, q:Item) -> if (p.ok) { first(); } else { second(); });\n\t}\n}';
	private static final BLOCK_CANON: String = 'class C {\n\tfunction test() {\n\t\titems.rank((p:Item, q:Item) -> if (p.ok) {\n'
		+ '\t\t\tfirst();\n\t\t} else {\n\t\t\tsecond();\n\t\t});\n\t}\n}';
	private static final OTHER_SRC: String = 'class C {\n\tfunction test() {\n\t\tfinal direct = if (flag) 1 else 0;\n'
		+ '\t\tfinal ternary = items.rank((p:Item, q:Item) -> p.orderKeyVal < q.orderKeyVal ? -1 : 1);\n'
		+ '\t\titems.rank((p:Item, q:Item) -> {\n\t\t\tif (p.orderKeyVal < q.orderKeyVal) return -1;\n\t\t\treturn 0;\n\t\t});\n\t}\n}';
	private static final OTHER_CANON: String = 'class C {\n\tfunction test() {\n\t\tfinal direct = if (flag)\n\t\t\t1\n\t\telse\n\t\t\t0;\n'
		+ '\t\tfinal ternary = items.rank((p:Item, q:Item) -> p.orderKeyVal < q.orderKeyVal ? -1 : 1);\n'
		+ '\t\titems.rank((p:Item, q:Item) -> {\n\t\t\tif (p.orderKeyVal < q.orderKeyVal) return -1;\n\t\t\treturn 0;\n\t\t});\n\t}\n}';
	private static final OBJECT_SRC: String = 'class C {\n\tfunction test() {\n\t\titems.rank((p:Item, q:Item) -> if (p.ok)\n'
		+ '\t\t\t// pick first\n\t\t\t{ alpha: p.a, beta: p.b }\n\t\telse\n' + '\t\t\t{ alpha: q.a, beta: q.b });\n\t}\n}';
	private static final OBJECT_CANON: String = 'class C {\n\tfunction test() {\n\t\titems.rank((p:Item, q:Item) -> if (p.ok)\n'
		+ '\t\t\t// pick first\n\t\t\t{alpha: p.a, beta: p.b }\n\t\telse\n\t\t\t{alpha: q.a, beta: q.b });\n' + '\t}\n}';
	private static final NO_ELSE_SRC: String =
		'class C {\n\tfunction test() {\n\t\tfinal kept = items.map(p -> if (p.orderKeyVal > 0) p.orderKeyVal);\n\t}\n}';
	private static final NO_ELSE_CANON: String =
		'class C {\n\tfunction test() {\n\t\tfinal kept = items.map(p -> if (p.orderKeyVal > 0)\n\t\t\tp.orderKeyVal);\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * The reported defect: the whole statement fits flat, and without a reflow
	 * channel the writer still emits the chain exploded. With the knob the
	 * chain collapses back onto one line.
	 */
	public function testFlatFittingArrowValueIfChainCollapses(): Void {
		Assert.equals(FLAT_SRC, reflow(FLAT_SRC));
	}

	/**
	 * The source-multiline keep floor: the SAME chain arriving already wrapped
	 * must reach the same flat result. A fix validated only on flat input is a
	 * no-op on the real file, which is always the wrapped one.
	 */
	public function testWrappedArrowValueIfChainConvergesToFlat(): Void {
		Assert.equals(FLAT_SRC, reflow(FLAT_KEPT));
	}

	/**
	 * Too wide to fit flat: the head breaks after `->` and each arm takes one
	 * line at the body indent, with its value glued to its own condition.
	 */
	public function testTooWideArrowValueIfChainBreaksOneArmPerLine(): Void {
		Assert.equals(WIDE_REFLOWED, reflow(WIDE_SRC));
	}

	public function testWrappedTooWideArrowValueIfChainConverges(): Void {
		Assert.equals(WIDE_REFLOWED, reflow(WIDE_KEPT));
	}

	/**
	 * Middle outcome: the chain does not fit at the arrow's column but DOES fit
	 * at the body indent, so the head break alone is enough and the arms rejoin.
	 * The decision is the enclosing `Group`'s, re-measured after the arrow
	 * break - pinned so the three-way outcome is a recorded contract.
	 */
	public function testArrowValueIfChainRejoinsWhenItFitsAtBodyIndent(): Void {
		Assert.equals(MID_REFLOWED, reflow(MID_SRC));
	}

	public function testFlatSourceKeepsPolicyShapeWithoutKnob(): Void {
		Assert.equals(FLAT_KEPT, keep(FLAT_SRC));
	}

	public function testWrappedSourceKeepsPolicyShapeWithoutKnob(): Void {
		Assert.equals(FLAT_KEPT, keep(FLAT_KEPT));
	}

	public function testTooWideSourceKeepsPolicyShapeWithoutKnob(): Void {
		Assert.equals(WIDE_KEPT, keep(WIDE_SRC));
	}

	/**
	 * Comment on the OUTERMOST member - the direction the `else`-spine walk
	 * cannot see, since the model carries no upward link. Covered by the
	 * refusing member stamping `_arrowValueIfBlocked` on its branch writes.
	 */
	public function testCommentOnOuterMemberRefusesWholeChain(): Void {
		Assert.equals(COMMENT_OUTER_SRC, reflow(COMMENT_OUTER_SRC));
		Assert.equals(COMMENT_OUTER_SRC, keep(COMMENT_OUTER_SRC));
	}

	/**
	 * Comment after an INNER member's condition - the direction the descent
	 * signal cannot see, since the outer member's own slots are clean.
	 * Covered by the `else`-spine walk.
	 */
	public function testCommentAfterInnerConditionRefusesWholeChain(): Void {
		Assert.equals(COMMENT_INNER_COND_SRC, reflow(COMMENT_INNER_COND_SRC));
		Assert.equals(COMMENT_INNER_COND_SRC, keep(COMMENT_INNER_COND_SRC));
	}

	public function testCommentOnInnerValueRefusesWholeChain(): Void {
		Assert.equals(COMMENT_INNER_VALUE_SRC, reflow(COMMENT_INNER_VALUE_SRC));
		Assert.equals(COMMENT_INNER_VALUE_SRC, keep(COMMENT_INNER_VALUE_SRC));
	}

	public function testCommentOnFinalElseRefusesWholeChain(): Void {
		Assert.equals(COMMENT_TAIL_SRC, reflow(COMMENT_TAIL_SRC));
		Assert.equals(COMMENT_TAIL_SRC, keep(COMMENT_TAIL_SRC));
	}

	/**
	 * Trailing comment on the chain's LAST value - the only comment position
	 * outside the `if` node's own trivia slots, since nothing of the node
	 * follows the final value. The slot belongs to the enclosing call's
	 * argument element, so neither the spine walk nor the `_arrowValueIfBlocked`
	 * descent can see it, and the chain used to re-flow with the comment
	 * dangling off the glued line.
	 */
	public function testTrailingCommentOnFinalValueRefusesWholeChain(): Void {
		Assert.equals(TRAIL_ON_TAIL_VALUE_SRC, reflow(TRAIL_ON_TAIL_VALUE_SRC));
		Assert.equals(TRAIL_ON_TAIL_VALUE_SRC, keep(TRAIL_ON_TAIL_VALUE_SRC));
	}

	public function testTrailingCommentOnElseValueRefusesTwoArmChain(): Void {
		Assert.equals(TRAIL_ON_ELSE_VALUE_SRC, reflow(TRAIL_ON_ELSE_VALUE_SRC));
		Assert.equals(TRAIL_ON_ELSE_VALUE_SRC, keep(TRAIL_ON_ELSE_VALUE_SRC));
	}

	/**
	 * A refused chain must leave the SIBLING arrow knobs alone. The refusal
	 * used to travel by clearing `_inArrowLambdaBody`, which also switched off
	 * the object-literal arrow open-pad inside the refused branch; with its own
	 * field the padding matches the knob-off output byte for byte.
	 */
	public function testRefusedChainLeavesObjectLiteralPaddingAlone(): Void {
		Assert.equals(OBJECT_CANON, write(OBJECT_SRC, CONFIG_OBJECT_ON));
		Assert.equals(OBJECT_CANON, write(OBJECT_SRC, CONFIG_OBJECT_OFF));
	}

	/**
	 * Block-bodied branches keep their cuddled `} else {`. The group is emitted
	 * even though such a body can never render flat: it commits to its break
	 * branch, which is the shape the branch already had. Gating the group on
	 * "can render flat" instead uncuddled every block-bodied branch.
	 */
	public function testBlockBodiedBranchesKeepCuddledElse(): Void {
		Assert.equals(BLOCK_CANON, reflow(BLOCK_SRC));
		Assert.equals(BLOCK_CANON, keep(BLOCK_SRC));
	}

	/**
	 * The else-less arrow-body `if` keeps its `noSiblingFallback` answer. Only
	 * visible under `ifBody: "next"` - with `fitLine` the fallback and the
	 * knob's forced `Same` agree, so the gate would pass either way.
	 */
	public function testElselessArrowBodyIfKeepsFallbackAnswer(): Void {
		Assert.equals(NO_ELSE_CANON, write(NO_ELSE_SRC, CONFIG_NEXT_ON));
		Assert.equals(NO_ELSE_CANON, write(NO_ELSE_SRC, CONFIG_NEXT_OFF));
	}

	/**
	 * Out of scope, all in one fixture: a non-arrow value-`if`, the ternary
	 * form, and a statement-`if` inside a block arrow body.
	 */
	public function testNonChainShapesAreUntouchedByTheKnob(): Void {
		Assert.equals(OTHER_CANON, reflow(OTHER_SRC));
		Assert.equals(OTHER_CANON, keep(OTHER_SRC));
	}

	public function testFlatOutcomeIsIdempotent(): Void {
		Assert.equals(FLAT_SRC, reflow(reflow(FLAT_SRC)));
	}

	public function testBreakOutcomeIsIdempotent(): Void {
		Assert.equals(WIDE_REFLOWED, reflow(reflow(WIDE_SRC)));
		Assert.equals(MID_REFLOWED, reflow(reflow(MID_SRC)));
	}

	public function testRefusedOutcomeIsIdempotent(): Void {
		Assert.equals(COMMENT_OUTER_SRC, reflow(reflow(COMMENT_OUTER_SRC)));
		Assert.equals(COMMENT_INNER_COND_SRC, reflow(reflow(COMMENT_INNER_COND_SRC)));
	}

	private inline function reflow(src: String): String {
		return write(src, CONFIG_ON);
	}

	private inline function keep(src: String): String {
		return write(src, CONFIG_OFF);
	}

	private function write(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
