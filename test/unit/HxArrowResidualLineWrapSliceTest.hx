package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-arrow-residual-linewrap: a `->`/`=>` lambda body carries a residual
 * line-wrap marker whose natural-first-line resolution DEFERS the rest-of-line
 * to any enclosing wrap construct — so a ternary, an `&&`/`||` condition chain,
 * or an assignment breaks FIRST and the arrow stays flat, instead of the arrow
 * pre-empting the outer break. When no outer construct competes (a sole call
 * arg, or a `??` operand that stays glued) the arrow breaks after `->` and its
 * close `)` lands on its own line, coupled to the same residual decision.
 * Identifiers are fully synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxArrowResidualLineWrapSliceTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	public function new(): Void {
		super();
	}

	/** A sole paren-arrow call arg whose line overflows breaks after `->` with the body indented and the close `)` on its own line — no competing outer construct. */
	public function testSoleArrowArgBreaksWithCloseOnOwnLine(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\tfinal picked:Null<WrapperResultType> = elementCollectionValue.find((element:MemberEntryType) -> ScoringHelperName.computeRankValueFor(element) == 1);\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal picked:Null<WrapperResultType> = elementCollectionValue.find((element:MemberEntryType) ->\n\t\t\tScoringHelperName.computeRankValueFor(element) == 1\n\t\t);\n\t}\n\n}',
			triviaWrite(src)
		);
	}

	/** A `cond ? a : b` whose condition is an arrow-arg call keeps the arrow FLAT and breaks the ternary at `?`/`:` (the arrow defers to the ternary). */
	public function testTernaryBreaksArrowStaysFlat(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\tfinal chosen = memberCollectionVal.exists((entry:MemberEntryType) -> entry.id == probe.id || entry.tag == probe.tagAddress) ? firstRankListValue : otherRankListValue;\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal chosen = memberCollectionVal.exists((entry:MemberEntryType) -> entry.id == probe.id || entry.tag == probe.tagAddress)\n\t\t\t? firstRankListValue\n\t\t\t: otherRankListValue;\n\t}\n\n}',
			triviaWrite(src)
		);
	}

	/** An `if (!x && exists(arrow) && exists(arrow))` opens the condition paren and breaks at `&&`, keeping both arrows FLAT (the arrows defer to the boolean chain). */
	public function testConditionAndChainOpensArrowsStayFlat(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\tif (!errorFlag && !firstBucketList.entries.exists((entry:BucketEntryType) -> entry.tag == probeValue) && !secondBucketList.entries.exists((entry:BucketEntryType) -> entry.tag == probeValue)) invokeTask();\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tif (\n\t\t\t!errorFlag && !firstBucketList.entries.exists((entry:BucketEntryType) -> entry.tag == probeValue)\n\t\t\t&& !secondBucketList.entries.exists((entry:BucketEntryType) -> entry.tag == probeValue)\n\t\t)\n\t\t\tinvokeTask();\n\t}\n\n}',
			triviaWrite(src)
		);
	}

	/** A `find(arrow) ?? find(arrow)` breaks the FIRST arrow (body indented, close `)` on its own line with `??` glued to it) and keeps the second arrow inline. */
	public function testNullCoalesceFirstArrowBreaksCloseCoupled(): Void {
		final src: String = 'class Sample {\n\tfunction run() {\n\t\treturn allPaths.findEntry(path -> isAvailableAt(path) && Path.directory(path) == newDirValue) ?? allPaths.findEntry(path -> isAvailableAt(path));\n\t}\n}';
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\treturn allPaths.findEntry(path ->\n\t\t\tisAvailableAt(path) && Path.directory(path) == newDirValue\n\t\t) ?? allPaths.findEntry(path -> isAvailableAt(path));\n\t}\n\n}',
			triviaWrite(src)
		);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
