package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-methodchain-callparam-restaware: a `callParameter` cascade-disagree
 * segment (`itemCount <= 1 && totalItemLength > 100`, so the break branch
 * LEADING-BREAKS the argument onto its own line) inside a DOT-BROKEN method
 * chain must decide flat-vs-break against its WHOLE physical line — including
 * the trailing tokens that share it — matching the fork's `exceedsMaxLineLength`
 * rather than the renderer's local per-segment `fitsFlat`. So a `.concat(arg)`
 * whose segment line reaches the limit leading-breaks (argument kept flat),
 * while the same chain at a shallower column, or a short argument that fits
 * the `noWrap` rule, stays glued.
 */
@:nullSafety(Strict)
final class HxMethodChainCallParamRestAwareSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testConcatArgStaysHuggedWhenSegmentFits(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r:Payload = holder.flag != null\n\t\t\t? holder.mainSource.first.filter(SomeUtils.notEmpty)\n\t\t\t\t.map(u -> makeEntry(u.label, u.status == OPEN))\n\t\t\t\t.concat(holder.mainSource.backups.filter(SomeUtils.notEmpty).map(u -> makeEntry(u.label, u.status == OPEN)))\n\t\t\t: null;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testShortConcatArgStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal result = holder.mainSource.first.filter(SomeUtils.notEmpty)\n\t\t\t.map(u -> makeEntry(u.label, u.status == OPEN))\n\t\t\t.concat(holder.mainSource.backups);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testLongConcatArgStaysGluedWhenSegmentFits(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal result = holder.mainSource.first.filter(SomeUtils.notEmpty)\n\t\t\t.map(u -> makeEntry(u.label, u.status == OPEN))\n\t\t\t.concat(holder.mainSource.backups.filter(SomeUtils.notEmpty).map(u -> makeEntry(u.label, u.status == OPEN)));\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * Genuine leading-break guard: a `.concat(ARG)` segment inside a DOT-BROKEN
	 * chain whose ARG (itself a method chain, totalItemLength > 100) makes the
	 * segment's physical line reach the limit must LEADING-BREAK the argument
	 * onto its own line (kept flat), matching the fork's whole-line
	 * `exceedsMaxLineLength`. Without the rest-aware `IfLineExceeds` swap the
	 * writer HUGS the argument (local `fitsFlat` is blind to the enclosing
	 * context), so this fails on the unfixed writer.
	 */
	public function testConcatArgLeadingBreaksInDotBrokenChain(): Void {
		final config: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';
		final src: String = 'class C {\n\n\tstatic function makeList<T>(actions:Array<Act>):Array<T> {\n\t\treturn [ for (action in actions) {\n\t\t\tfinal a:Payload = {\n\t\t\t\taddItems: holder.mainGroups != null\n\t\t\t\t\t? holder.mainGroups.first.filter(SomeUtils.notEmpty)\n\t\t\t\t\t\t.map(u -> {label: u.label, enabled: u.status == OPEN })\n\t\t\t\t\t\t.concat(\n\t\t\t\t\t\t\tholder.mainGroups.backups.filter(SomeUtils.notEmpty).map(u -> {label: u.label, enabled: u.status == OPEN })\n\t\t\t\t\t\t)\n\t\t\t\t\t: null\n\t\t\t};\n\t\t} ];\n\t}\n\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		opts.finalNewline = false;
		Assert.equals(src, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
