package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * A leading-break function signature must pack ALL params onto the continuation
 * line while they fit within maxLineLength. The LAST param was breaking onto its
 * own line one column early: the fill's per-line trailing-comma reserve
 * spuriously bound the last item, which has nothing after it on its line (the
 * `)` sits on its own line). A param line of width 139 (<= 140) must stay inline;
 * width 140 (fork breaks fill items AT the limit) and beyond still break.
 * Identifiers are synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxFnSigFillLastParamBoundaryTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "functionSignature": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 100}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	/** Param line at width 139 (<= 140): all nine params stay on the continuation line. */
	public function testLastParamFitsInlineAtBoundary(): Void {
		final src: String = 'class M {\n\tpublic static function processTactic(alphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, echoPt:Float, foxtrotQ:Float, golfIdx:Float, hotelLen:Float, id:Float):Void {\n\t\ttrace(id);\n\t}\n}';
		final expected: String = 'class M {\n\tpublic static function processTactic(\n\t\talphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, echoPt:Float, foxtrotQ:Float, golfIdx:Float, hotelLen:Float, id:Float\n\t):Void {\n\t\ttrace(id);\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	/** GUARD: param line at width 140 (fork breaks fill items AT the limit): last param on its own line. */
	public function testLastParamBreaksAtLimit(): Void {
		final src: String = 'class M {\n\tpublic static function processTactic(alphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, echoPt:Float, foxtrotQ:Float, golfIdx:Float, hotelLen:Float, idx:Float):Void {\n\t\ttrace(idx);\n\t}\n}';
		final expected: String = 'class M {\n\tpublic static function processTactic(\n\t\talphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, echoPt:Float, foxtrotQ:Float, golfIdx:Float, hotelLen:Float,\n\t\tidx:Float\n\t):Void {\n\t\ttrace(idx);\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
