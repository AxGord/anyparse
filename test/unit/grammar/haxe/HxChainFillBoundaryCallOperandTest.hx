package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A `+`/`-` (opAddSubChain) fill packs operands per line while the row stays within `maxLineLength`. A CALL operand
 * whose flat form ends at EXACTLY the limit stays on the packed row whole: the call's own break probe agrees with the
 * fill that a row of exactly the width fits, so its arguments never split (`toUnits(\n\tmemoryValue\n)`) to keep it there.
 */
@:nullSafety(Strict)
final class HxChainFillBoundaryCallOperandTest extends Test {

	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.sameLineExpressionElse = SameLinePolicy.SameOnBlock;
		edited.expressionIfBody = BodyPolicy.Next;
		edited.expressionElseBody = BodyPolicy.Next;
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
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap },
				{
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 1 },
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 100 }
					],
					mode: WrapMode.NoWrap
				}
			]
		};
		edited.opBoolChainWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.NoWrap,
			rules: [
				{
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					],
					mode: WrapMode.NoWrap
				},
				{
					conditions: [
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 120 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					],
					mode: WrapMode.NoWrap
				},
				{
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }],
					location: WrappingLocation.BeforeLast,
					mode: WrapMode.FillLine
				}
			]
		};
		edited.opAddSubChainWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.NoWrap,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap },
				{
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }],
					location: WrappingLocation.BeforeLast,
					mode: WrapMode.FillLine
				}
			]
		};
		edited.conditionWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
			]
		};
		edited.expressionWrappingWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
			]
		};
		edited.functionTypeHaxe4 = WhitespacePolicy.None;
	});

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-PROBE-GLUED-ALWAYS')
	public function testCallOperandEndingAtLimitStaysWhole(): Void {
		final flat: String = 'class C {\n\tfunction f() {\n'
			+ '\t\treturn \'DiagReport\' + line() + \'{\' + line() + \'  aa : \' + hostId + line() + \'  mem: \' + '
			+ 'memoryValue + \' KB (\' + toUnits(memoryValue) + \' GB)\' + line() + \'  cpu: \' + coreTag + \'}\';\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n'
			+ "\t\treturn 'DiagReport' + line() + '{' + line() + '  aa : ' + hostId + line() + '  mem: ' + memoryValue + ' KB ('"
			+ " + toUnits(memoryValue)\n\t\t\t+ ' GB)' + line() + '  cpu: ' + coreTag + '}';\n\t}\n}";
		final out: String = triviaWrite(flat);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
		Assert.isTrue(out.indexOf('toUnits(memoryValue)') >= 0);
		Assert.isTrue(out.indexOf('toUnits(\n') < 0);
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
