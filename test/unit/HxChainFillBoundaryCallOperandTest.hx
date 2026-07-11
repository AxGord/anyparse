package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-chain-fill-operand-boundary: a `+`/`-` (opAddSubChain) fill packs
 * operands per line until one overflows. A CALL operand whose flat form ends
 * at EXACTLY `maxLineLength` must NOT stay glued on the packed line -- the
 * fork's fill boundary is `>=` (the operator that follows needs room), so the
 * chain breaks at the operator and the call stays intact. Before the fix
 * `shapeFillLine` used the Wadler-inclusive raw `Fill` (glue at a zero-budget
 * exact fit), so the call sat flush at the limit and its own args split
 * (`toUnits(\n\tmemoryValue\n)`) while the chain stayed flat. `shapeFillLine`
 * now reserves the `+ 1` fork-`>=` boundary on the chain `Fill` so a middle
 * operand ending at the limit wraps at the operator instead.
 */
@:nullSafety(Strict)
final class HxChainFillBoundaryCallOperandTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opAddSubChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "whitespace": {"commaPolicy": "after", "binopPolicy": "around", "arrowFunctionsPolicy": "around", "functionTypeHaxe3Policy": "none", "functionTypeHaxe4Policy": "none"}, "sameLine": {"expressionIf": "next"}}';

	public function new(): Void {
		super();
	}

	public function testCallOperandEndingAtLimitKeepsChainBreak(): Void {
		final flat: String = "class C {\n\tfunction f() {\n\t\treturn 'DiagReport' + line() + '{' + line() + '  aa : ' + hostId + line() + '  mem: ' + memoryValue + ' KB (' + toUnits(memoryValue) + ' GB)' + line() + '  cpu: ' + coreTag + '}';\n\t}\n}";
		final wrapped: String = "class C {\n\tfunction f() {\n\t\treturn 'DiagReport' + line() + '{' + line() + '  aa : ' + hostId + line() + '  mem: ' + memoryValue + ' KB ('\n\t\t\t+ toUnits(memoryValue) + ' GB)' + line() + '  cpu: ' + coreTag + '}';\n\t}\n}";
		final out: String = triviaWrite(flat);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
		Assert.isTrue(out.indexOf("toUnits(memoryValue)") >= 0);
		Assert.isTrue(out.indexOf("toUnits(\n") < 0);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
