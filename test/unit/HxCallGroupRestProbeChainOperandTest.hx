package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-call-grouprestprobe-subposition (chain operand): a `Call` that is an
 * operand of a wrapping `+`/`-`/`||`/`&&` chain must NOT split its own args by
 * counting the whole chain tail against them. `groupRestProbe` on the operand
 * `Call` would over-count the rest-of-chain and split a head call that fits on
 * its own line; `lowerInfixChain` sets `_suppressCallRestProbe` on every chain
 * leaf operand so it reverts to plain-Group (wrap-on-own-overflow) while the
 * chain absorbs overflow via its operator break / paren-open. Mirrors the
 * `??`-operand and case-pattern guards.
 */
@:nullSafety(Strict)
final class HxCallGroupRestProbeChainOperandTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opAddSubChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "whitespace": {"commaPolicy": "after", "binopPolicy": "around", "arrowFunctionsPolicy": "around", "functionTypeHaxe3Policy": "none", "functionTypeHaxe4Policy": "none"}, "sameLine": {"expressionIf": "next"}}';

	public function new(): Void {
		super();
	}

	public function testChainHeadCallStaysFlat(): Void {
		final glued: String = "class C {\n\tfunction f() {\n\t\treturn w('some sample caption:', 100) + ' ' + (opts != null && opts.length != 0 ? PathUtil.removeSuffixText(opts[0], false) : 'default value') + (selectedCount > 1 ? ' + ${selectedCount - 1} ${w('more', 200)}' : '');\n\t}\n}";
		final wrapped: String = "class C {\n\tfunction f() {\n\t\treturn w('some sample caption:', 100) + ' ' + (\n\t\t\topts != null && opts.length != 0 ? PathUtil.removeSuffixText(opts[0], false) : 'default value'\n\t\t) + (selectedCount > 1 ? ' + ${selectedCount - 1} ${w('more', 200)}' : '');\n\t}\n}";
		final out: String = triviaWrite(glued);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
		Assert.isTrue(out.indexOf("w('some sample caption:', 100)") >= 0);
		Assert.isTrue(out.indexOf('w(\n') < 0);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
