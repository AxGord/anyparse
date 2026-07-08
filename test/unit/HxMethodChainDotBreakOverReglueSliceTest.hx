package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-methodchain-reeval-after-callparam scope: the chain re-glue (strip the
 * dot-break, absorb the overflow into the LAST segment's call args) fires
 * ONLY when the dot-break is USELESS — the last segment overflows even on
 * its own continuation line after a dot-break, so its args must break
 * regardless. When a dot-break alone makes every chain line fit, the chain
 * keeps its dot-break and the last call's args stay flat (fork
 * `breakLongMethodChains` per-dot overflow semantics; fork
 * `reEvaluateMethodChainAfterCallParam` re-glues only in reaction to an
 * INDEPENDENT callParameter break).
 */
@:nullSafety(Strict)
final class HxMethodChainDotBreakOverReglueSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testDotBreakKeptWhenArrowSegmentFitsAfterBreak(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal result = alpha.beta.filter(SomeHelper.isValid)\n\t\t\t.map(u -> makeEntry(u.name, u.level == HIGH1))\n\t\t\t.concat(alpha.gamma.filter(SomeHelper.isValid).map(u -> makeEntry(u.name, u.level == HIGH1)));\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testDotBreakKeptWhenLastSegmentFitsAfterBreak(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.getInstance()\n\t\t\t.add(longArgumentAlphaValue, longArgumentBravoValue, longArgumentCharlieValue, longArgumentDeltaValue, longArgumentEchoValue);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testReglueKeptWhenLastSegmentOverflowsAfterBreak(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.getInstance().add(\n\t\t\tlongArgumentAlphaValue, longArgumentBravoValue, longArgumentCharlieValue, longArgumentDeltaValue, longArgumentEchoValue,\n\t\t\tlongArgumentFoxtrotValue\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testGlueKeptWhenSegmentBodiesForceBreaks(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tservice.request({\n\t\t\talpha: alphaValue,\n\t\t\tbeta: betaValue\n\t\t}).success(response -> {\n\t\t\thideMask();\n\t\t\tapply(response);\n\t\t}).error(response -> {\n\t\t\thideMask();\n\t\t\treport(response);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
