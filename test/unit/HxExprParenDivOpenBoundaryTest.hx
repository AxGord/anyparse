package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

using StringTools;

/**
 * expr-paren-open pending-space: an `x = (chain) / lit;` whose parenthesised
 * opAddSub chain makes the physical line exceed maxLineLength OPENS the paren,
 * matching the fork. The paren-open probe restores the un-flushed OptSpace after
 * `=` (not yet in the pen column when the probe fires) so a line at exactly
 * maxLineLength + 1 opens rather than staying glued. Identifiers are synthetic.
 */
@:nullSafety(Strict)
final class HxExprParenDivOpenBoundaryTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	public function new(): Void {
		super();
	}

	/** Physical line 141 (maxLineLength + 1): the paren OPENS. */
	public function testDivParenOpensWhenLineOverflows(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tcontainerBox.y = (\n\t\t\tWINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPAN\n\t\t) / 2.0;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tcontainerBox.y = (WINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPAN) / 2.0;\n\t}\n}',
				CFG
			)
		);
	}

	/** BOUNDARY: physical line EXACTLY 140 stays glued (a line at the limit does not exceed it) -- guards the pending-space off-by-one. */
	public function testDivParenFlatAtExactLimit(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tcontainerBox.y = (WINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPA) / 2.0;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tcontainerBox.y = (WINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPA) / 2.0;\n\t}\n}',
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
