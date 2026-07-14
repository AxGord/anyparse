package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ternary-rest-aware: a ternary that is a leading-break CALL ARGUMENT wraps
 * `cond ? then : else` when its physical line -- INCLUDING the trailing `,`
 * separator the call's Fill emits on the same line -- exceeds maxLineLength,
 * matching the fork. A plain Group(IfBreak) measures `col + flatWidth` only and
 * misses the on-line comma, leaving such a boundary ternary flat at
 * maxLineLength + 1. Identifiers are fully synthetic.
 */
@:nullSafety(Strict)
final class HxTernaryCallArgRestAwareTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	public function new(): Void {
		super();
	}

	/**
	 * arg1's physical line is 141 (140 flat + the trailing `,`): it WRAPS.
	 */
	public function testTernaryCallArgWrapsWhenCommaOverflows(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tviewport.setTo(\n\t\t\tmeasureA >= (LAYOUT_PRIMARY_SPAN * zoomFactor)\n\t\t\t\t? LAYOUT_PRIMARY_SPAN / 2\n\t\t\t\t: (measureA / 2 - scrollAnchor.x) * pixelsPerContentUni,\n\t\t\tmeasureB >= (LAYOUT_SECOND_SPAN * zoomFactor) ? LAYOUT_SECOND_SPAN / 2 : (measureB / 2 - scrollAnchor.y) * pixelsPerContentUnitX\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tviewport.setTo(measureA >= (LAYOUT_PRIMARY_SPAN * zoomFactor) ? LAYOUT_PRIMARY_SPAN / 2 : (measureA / 2 - scrollAnchor.x) * pixelsPerContentUni, measureB >= (LAYOUT_SECOND_SPAN * zoomFactor) ? LAYOUT_SECOND_SPAN / 2 : (measureB / 2 - scrollAnchor.y) * pixelsPerContentUnitX);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * BOUNDARY: arg1's physical line is EXACTLY 140 (the `,` included) -- it stays
	 * FLAT (a line at the limit does not exceed it). Guards the off-by-one where a
	 * broken separator's dropped trailing space was miscounted.
	 */
	public function testTernaryCallArgFlatAtExactLimit(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tviewport.setTo(\n\t\t\tmeasureA >= (LAYOUT_PRIMARY_SPAN * zoomFactor) ? LAYOUT_PRIMARY_SPAN / 2 : (measureA / 2 - scrollAnchor.x) * pixelsPerContentUn,\n\t\t\tmeasureB >= (LAYOUT_SECOND_SPAN * zoomFactor) ? LAYOUT_SECOND_SPAN / 2 : (measureB / 2 - scrollAnchor.y) * pixelsPerContentUnitX\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tviewport.setTo(measureA >= (LAYOUT_PRIMARY_SPAN * zoomFactor) ? LAYOUT_PRIMARY_SPAN / 2 : (measureA / 2 - scrollAnchor.x) * pixelsPerContentUn, measureB >= (LAYOUT_SECOND_SPAN * zoomFactor) ? LAYOUT_SECOND_SPAN / 2 : (measureB / 2 - scrollAnchor.y) * pixelsPerContentUnitX);\n\t}\n}',
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
