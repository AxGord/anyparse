package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * opadd-trailing-paren-break: a 2-operand `a + (bare paren)` whose paren wraps a
 * same-class opAddSub subexpression (`(b - c)`) BREAKS the chain beforeLast when
 * the line overflows and the paren fits its continuation, matching the fork
 * (`unwrapAddOps`). A paren wrapping a ternary (or other-class operator) is
 * content the fork keeps GLUED (opens the paren). Identifiers are synthetic.
 */
@:nullSafety(Strict)
final class HxOpAddParenInnerBreakTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

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

	/** DISCRIMINATOR: a ternary-inner paren OPENS (glues), it does NOT break the chain. */
	public function testTernaryInnerParenOpensNotBreaks(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tpivotAnchorInverted.horizontalPosValue = slideMovementOrigin.horizontal + (\n\t\t\ttogglePointerActiveNowFlag ? slidePointerTrackingHorizontalX : baseX\n\t\t);\n\t}\n\n}',
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
