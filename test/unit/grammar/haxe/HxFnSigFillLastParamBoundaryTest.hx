package unit.grammar.haxe;

import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A leading-break function signature must pack ALL params onto the continuation
 * line while they fit within maxLineLength. The LAST param was breaking onto its
 * own line one column early: the fill's per-line trailing-comma reserve
 * spuriously bound the last item, which has nothing after it on its line (the
 * `)` sits on its own line). A param line of width 139 or 140 stays inline; 141
 * breaks.
 * Identifiers are synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxFnSigFillLastParamBoundaryTest extends Test {

	private static final CFG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.functionSignatureWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{
					conditions: [
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 100 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					],
					mode: WrapMode.NoWrap
				},
				{ conditions: [{ cond: WrapConditionType.ItemCountLessThan, value: 1 }], mode: WrapMode.NoWrap }
			]
		};
	});

	public function new(): Void {
		super();
	}

	/** Param line at width 139 (<= 140): all nine params stay on the continuation line. */
	public function testLastParamFitsInlineAtBoundary(): Void {
		final src: String = 'class M {\n'
			+ '\tpublic static function processTactic(alphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, '
			+ 'echoPt:Float, foxtrotQ:Float, golfIdx:Float, hotelLen:Float, id:Float):Void {\n\t\ttrace(id);\n\t}\n}';
		final expected: String = 'class M {\n\tpublic static function processTactic(\n'
			+ '\t\talphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, echoPt:Float, foxtrotQ:Float, golfIdx:Float, '
			+ 'hotelLen:Float, id:Float\n\t):Void {\n\t\ttrace(id);\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	/** Param line at width 140, exactly the limit: all nine params stay on the continuation line. */
	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-FORK')
	public function testLastParamFitsInlineAtLimit(): Void {
		final src: String = 'class M {\n'
			+ '\tpublic static function processTactic(alphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, '
			+ 'echoPt:Float, foxtrotQ:Float, golfIdx:Float, hotelLen:Float, idx:Float):Void {\n\t\ttrace(idx);\n\t}\n}';
		final expected: String = 'class M {\n\tpublic static function processTactic(\n'
			+ '\t\talphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, echoPt:Float, foxtrotQ:Float, golfIdx:Float, '
			+ 'hotelLen:Float, idx:Float\n\t):Void {\n\t\ttrace(idx);\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	/** Param line at width 141, one past the limit: the last param goes on its own line. */
	@:pin('control')
	@:killer('M-FILL-LAST-TAIL-SLACK')
	public function testLastParamBreaksPastLimit(): Void {
		final src: String = 'class M {\n'
			+ '\tpublic static function processTactic(alphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, '
			+ 'echoPt:Float, foxtrotQ:Float, golfIdx:Float, hotelLen:Float, idxx:Float):Void {\n\t\ttrace(idxx);\n\t}\n}';
		final expected: String = 'class M {\n\tpublic static function processTactic(\n'
			+ '\t\talphaVal:Float, bravoVal:Float, charlie:Float, deltaXy:Float, echoPt:Float, foxtrotQ:Float, golfIdx:Float, '
			+ 'hotelLen:Float,\n\t\tidxx:Float\n\t):Void {\n\t\ttrace(idxx);\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CFG);
	}

}
