package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

using StringTools;

/**
 * omega-opadd-trailing-paren-glue: an overflowing `+`/`-` chain whose LAST
 * operand is a bare paren-expr that OPENS (leading-breaks after `(` under a
 * fillLine-family expressionWrapping) keeps the chain head GLUED on the open
 * line (`a - b - (` then the inner nested, `)` on its own line) instead of
 * breaking the operator onto a continuation line. At the universal default
 * (no expressionWrapping) the paren stays content-glued (`- (inner`), the
 * natural-first-line probe never selects the glue shape, and the chain keeps
 * its operator break. Identifiers are fully synthetic.
 */
@:nullSafety(Strict)
final class HxOpAddTrailingParenGlueSliceTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	private static final EXPR_WRAP_SECTION: String = '"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},';

	private static final SRC: String = 'class Sample {\n\tfunction run() {\n\t\tgraphicPanel.y = Boundaries.NODE_PACK_MESH_CELL_EXTENT - photo.extent - (toggle ? linkedToggle ? Boundaries.NODE_PACK_MESH_BADGEMARK_LINKED_TOGGLE_LOWEST_SPACING : Boundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING : Boundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING);\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Under a fillLine-family expressionWrapping the opened trailing paren keeps the chain head glued: `a - b - (` on one line. */
	public function testFillLineGluesChainHeadToOpenedTrailingParen(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tgraphicPanel.y = Boundaries.NODE_PACK_MESH_CELL_EXTENT - photo.extent - (\n\t\t\ttoggle\n\t\t\t\t? linkedToggle\n\t\t\t\t\t? Boundaries.NODE_PACK_MESH_BADGEMARK_LINKED_TOGGLE_LOWEST_SPACING\n\t\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING\n\t\t);\n\t}\n\n}',
			triviaWrite(SRC, CFG)
		);
	}

	/** Without expressionWrapping (universal default) the paren stays content-glued and the chain keeps its operator break. */
	public function testDefaultConfigKeepsOperatorBreak(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tgraphicPanel.y = Boundaries.NODE_PACK_MESH_CELL_EXTENT - photo.extent\n\t\t\t- (toggle\n\t\t\t\t? linkedToggle\n\t\t\t\t\t? Boundaries.NODE_PACK_MESH_BADGEMARK_LINKED_TOGGLE_LOWEST_SPACING\n\t\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_TOGGLE_LOWEST_SPACING\n\t\t\t\t: Boundaries.NODE_PACK_MESH_BADGEMARK_LOWEST_SPACING);\n\t}\n\n}',
			triviaWrite(SRC, CFG.replace(EXPR_WRAP_SECTION, ''))
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
