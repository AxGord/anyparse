package unit.grammar.haxe;

import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

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

	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.callParameterWrap = {
			containerItemWrap: {
				defaultMode: WrapMode.OnePerLine,
				rules: [
					{
						conditions: [
							{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
							{ cond: WrapConditionType.HasContainerItems, value: 0 },
							{ cond: WrapConditionType.TotalItemLengthLessThan, value: 60 }
						],
						mode: WrapMode.FillLine
					}
				]
			},
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
			]
		};
	});

	public function new(): Void {
		super();
	}

	public function testMultiArgTrailingThinBlockLambdaGluesHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.registerHandler(HandlerKind.PRIMARY, HandlerScope.GLOBAL, result '
			+ '-> {\n\t\t\tprocess(result);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testMultiArgTrailingParenBlockLambdaStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.registerHandler(HandlerKind.PRIMARY, HandlerScope.GLOBAL, ('
			+ 'result) -> {\n\t\t\tprocess(result);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testMultiArgLambdaFirstThenArgGluesHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.invokeHandlerCallback((resultValue) -> {\n'
			+ '\t\t\tprocess(resultValue);\n\t\t}, secondCallbackArg);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testMultiArgLambdaInMiddleGluesHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.invokeHandlerCallback(leadingArgValue, (resultValue) -> {\n'
			+ '\t\t\tprocess(resultValue);\n\t\t}, trailingArgValue);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testMultiArgTwoBlockLambdasGlueHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.invokeHandlerCallback((alphaValue) -> {\n'
			+ '\t\t\tstepAlpha(alphaValue);\n\t\t}, (bravoValue) -> {\n\t\t\tstepBravo(bravoValue);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testMultiArgNoLambdaStillLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmanager.invokeHandlerCallback(\n\t\t\targumentAlphaLongValueHere, '
			+ 'argumentBravoLongValueHere, argumentCharlieLongValueHere, argDeltaEpsilonZetaValue\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
