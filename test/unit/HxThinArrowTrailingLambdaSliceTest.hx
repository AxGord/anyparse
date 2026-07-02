package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-thin-arrow-body-marker: the infix `->` lambda (`arg -> body`)
 * carries the same arrow-body wrap marker as the parenthesised
 * `(arg) -> body` form, so a multi-arg call whose LAST arg is a
 * block-bodied THIN lambda keeps its head args glued to the open
 * paren under `callParameter.defaultWrap: fillLineWithLeadingBreak`
 * — the lambda's block supplies the only break and the call close
 * glues to the block close (`});`). Without the marker the cascade
 * opened the outer paren and pushed every arg one indent deeper.
 */
@:nullSafety(Strict)
final class HxThinArrowTrailingLambdaSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testMultiArgTrailingThinBlockLambdaGluesHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.registerHandler(HandlerKind.PRIMARY, HandlerScope.GLOBAL, result -> {\n\t\t\tprocess(result);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testMultiArgTrailingParenBlockLambdaStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.registerHandler(HandlerKind.PRIMARY, HandlerScope.GLOBAL, (result) -> {\n\t\t\tprocess(result);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
