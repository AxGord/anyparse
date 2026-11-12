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

	public function testCallOperandEndingAtLimitKeepsChainBreak(): Void {
		final flat: String = 'class C {\n\tfunction f() {\n'
			+ '\t\treturn \'DiagReport\' + line() + \'{\' + line() + \'  aa : \' + hostId + line() + \'  mem: \' + '
			+ 'memoryValue + \' KB (\' + toUnits(memoryValue) + \' GB)\' + line() + \'  cpu: \' + coreTag + \'}\';\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n'
			+ "\t\treturn 'DiagReport' + line() + '{' + line() + '  aa : ' + hostId + line() + '  mem: ' + memoryValue + ' KB ('\n"
			+ "\t\t\t+ toUnits(memoryValue) + ' GB)' + line() + '  cpu: ' + coreTag + '}';\n\t}\n}";
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
