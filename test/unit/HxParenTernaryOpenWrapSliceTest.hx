package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

using StringTools;

/**
 * omega-ternary-paren-open: an expression paren whose inner is a top-level
 * ternary stays `(`-glued at the universal expressionWrapping default (fork
 * parity, guarded by the ternary_collapse_after_opadd corpus fixture), but
 * under a fillLine-family expressionWrapping mode the overflowing paren OPENS:
 * break after `(`, ternary nested one level, close `)` on its own line —
 * instead of gluing `)` to the last ternary branch. Identifiers are fully
 * synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxParenTernaryOpenWrapSliceTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	private static final EXPR_WRAP_SECTION: String = '"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},';

	private static final SRC: String = 'class Sample {\n\tfunction run() {\n\t\tspriteMarkItem.x = offsetX + (node.bucket ? MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON : !_fixedMarkSearch ? MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON : MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON_FIXED_MARK_SEARCH);\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * Under a fillLine-family expressionWrapping the overflowing paren-ternary OPENS with the chain head glued: `offsetX + (` on one line, close `)` on its own line.
	 */
	public function testFillLineExpressionWrapOpensParenTernary(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tspriteMarkItem.x = offsetX + (\n\t\t\tnode.bucket\n\t\t\t\t? MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON\n\t\t\t\t: !_fixedMarkSearch\n\t\t\t\t\t? MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON\n\t\t\t\t\t: MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON_FIXED_MARK_SEARCH\n\t\t);\n\t}\n\n}',
			triviaWrite(SRC, CFG)
		);
	}

	/** Without expressionWrapping (universal default) the paren stays glued to the ternary on both sides — the config gate keeps fork default-config parity. */
	public function testDefaultExpressionWrapKeepsParenTernaryGlued(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tspriteMarkItem.x = offsetX\n\t\t\t+ (node.bucket\n\t\t\t\t? MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON\n\t\t\t\t: !_fixedMarkSearch\n\t\t\t\t\t? MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON\n\t\t\t\t\t: MeasureMap.PANEL_ROW_GRID_INDENT_MARK_ICON_FIXED_MARK_SEARCH);\n\t}\n\n}',
			triviaWrite(SRC, CFG.replace(EXPR_WRAP_SECTION, ''))
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}


	/**
	 * omega-ternary-paren-open BOUNDARY: an expression paren wrapping a top-level
	 * ternary whose flat line is EXACTLY maxLineLength (140) stays FLAT under a
	 * fillLine expressionWrapping mode — the open probe uses strict `>` (fork
	 * parity: a line AT the limit does not exceed it). Guards the off-by-one where
	 * the paren opened at exactly the limit.
	 */
	public function testExactMaxLineLengthKeepsParenTernaryFlat(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\treturn baseSpan != null ? baseSpan - (headNode != null ? headNode.width - gapMetr + headNode.padStart * 2 : 0) - tailPad * 2 : null;\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\treturn baseSpan != null ? baseSpan - (headNode != null ? headNode.width - gapMetr + headNode.padStart * 2 : 0) - tailPad * 2 : null;\n\t}\n\n}',
			triviaWrite(src, CFG)
		);
	}


	/**
	 * omega-ternary-paren-open BOUNDARY (opAddSub sibling): an expression paren
	 * wrapping a pure opAddSub chain whose flat line is EXACTLY maxLineLength (140)
	 * stays FLAT — same strict-`>` open probe as the ternary branch.
	 */
	public function testExactMaxLineLengthKeepsParenOpAddSubFlat(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\treturn baseSpan != null ? baseSpanValue - (headWidthValueX + gapMetricValueXY + padStartValFinalXX) - tailPaddingValueHereXX : null;\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\treturn baseSpan != null ? baseSpanValue - (headWidthValueX + gapMetricValueXY + padStartValFinalXX) - tailPaddingValueHereXX : null;\n\t}\n\n}',
			triviaWrite(src, CFG)
		);
	}

	/**
	 * omega-ternary-paren-open BOUNDARY (opBool sibling): an expression paren
	 * wrapping an opBool chain whose flat line is EXACTLY maxLineLength (140) stays
	 * FLAT — same strict-`>` open probe as the ternary branch.
	 */
	public function testExactMaxLineLengthKeepsParenOpBoolFlat(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\tif (isArrowBodyMarkerLongName || isMethodChainItemLong || !(startsCollectionDelimHere || firstBreakIsArrayDelimValXXXXX)) return -1;\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tif (isArrowBodyMarkerLongName || isMethodChainItemLong || !(startsCollectionDelimHere || firstBreakIsArrayDelimValXXXXX)) return -1;\n\t}\n\n}',
			triviaWrite(src, CFG)
		);
	}

}
