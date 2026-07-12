package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-call-grouprestprobe-subposition (nested call argument): a `Call` that
 * is itself an ARGUMENT of an outer wrapping call must NOT split its own args by
 * counting the outer call's sibling args + trailing `;` against them.
 * `groupRestProbe` on the inner arg-`Call` over-counts the rest of the physical
 * line, so an inner call that fits flat gets split while the outer call stays
 * glued. The outer call should wrap (open its paren) first, keeping the inner
 * call flat. Mirrors the `??`-operand, case-pattern, and chain-operand guards.
 */
@:nullSafety(Strict)
final class HxCallGroupRestProbeNestedArgTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opAddSubChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "whitespace": {"commaPolicy": "after", "binopPolicy": "around", "arrowFunctionsPolicy": "around", "functionTypeHaxe3Policy": "none", "functionTypeHaxe4Policy": "none"}, "sameLine": {"expressionIf": "next"}}';

	public function new(): Void {
		super();
	}

	public function testInnerArgCallStaysFlat(): Void {
		final glued: String = "class C {\n\tprivate final _widget:Widget = new Widget(w('SampleCaption', 207), StyleFactory.buildDefaultTextFormat(), 64, 20, Palette.PANEL_BG_GREY);\n}";
		final wrapped: String = "class C {\n\tprivate final _widget:Widget = new Widget(\n\t\tw('SampleCaption', 207), StyleFactory.buildDefaultTextFormat(), 64, 20, Palette.PANEL_BG_GREY\n\t);\n}";
		final out: String = triviaWrite(glued);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
		Assert.isTrue(out.indexOf("w('SampleCaption', 207)") >= 0);
		Assert.isTrue(out.indexOf("w(\n") < 0);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
