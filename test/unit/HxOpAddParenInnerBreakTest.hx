package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * opadd-trailing-paren-break: a 2-operand `a OP (bare paren)` whose rendered line
 * overflows BREAKS the chain beforeLast when the paren fits its own continuation
 * line, leaving the delimited group intact and the break at the outer boundary.
 *
 * The class of the operator INSIDE the paren is not a gate (T37 retired that
 * restriction — a deliberate divergence from fork `unwrapAddOps`, which keeps a
 * ternary-inner paren glued). Only a paren too wide to fit the continuation falls
 * through to the glue probe. Identifiers are synthetic.
 */
@:nullSafety(Strict)
final class HxOpAddParenInnerBreakTest extends Test {

	private static final CFG: String =
		'{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	public function new(): Void {
		super();
	}

	/** opAddSub-inner paren `(b - c)`, physical line 141: the chain BREAKS. */
	public function testOpAddSubInnerParenBreaksBeforeLast(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tpivotAnchorInverted.horizontalPos = slideMovementOrigin.horizontal\n\t\t\t+ (slidePointerTracking.horizontalX - originTrackingPointerBaseX);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tpivotAnchorInverted.horizontalPos = slideMovementOrigin.horizontal + (slidePointerTracking.horizontalX - originTrackingPointerBaseX);\n\t}\n}',
				CFG
			)
		);
	}

	/** BOUNDARY: physical line EXACTLY 140 stays flat. */
	public function testOpAddSubInnerParenFlatAtLimit(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tpivotAnchorInverted.horizontalPos = slideMovementOrigin.horizontal + (slidePointerTracking.horizontalX - originTrackingPointerBase);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tpivotAnchorInverted.horizontalPos = slideMovementOrigin.horizontal + (slidePointerTracking.horizontalX - originTrackingPointerBase);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * RE-PINNED (T37): a ternary-inner paren BREAKS the chain, exactly as an
	 * opAddSub-inner one does. The operand class of the paren contents was this arm
	 * gate until T37 and is no longer — the rule is that a break inside an inner `()`
	 * is less preferable than a break at an outer boundary, and `?` vs `-` inside the
	 * group says nothing about which boundary is outer. Deliberate divergence from
	 * fork `unwrapAddOps`. The paren still has to FIT its own continuation line; a
	 * wider one stays on the glue probe via the `contWidth > lineWidth` prune.
	 */
	public function testTernaryInnerParenBreaksTheChain(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tpivotAnchorInverted.horizontalPosValue = slideMovementOrigin.horizontal\n\t\t\t+ (togglePointerActiveNowFlag ? slidePointerTrackingHorizontalX : baseX);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tpivotAnchorInverted.horizontalPosValue = slideMovementOrigin.horizontal + (togglePointerActiveNowFlag ? slidePointerTrackingHorizontalX : baseX);\n\t}\n}',
				CFG
			)
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
