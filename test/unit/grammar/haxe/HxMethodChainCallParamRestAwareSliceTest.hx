package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-methodchain-callparam-restaware: a `callParameter` cascade-disagree
 * segment (`itemCount <= 1 && totalItemLength > 100`, so the break branch
 * LEADING-BREAKS the argument onto its own line) inside a DOT-BROKEN method
 * chain must decide flat-vs-break against its WHOLE physical line — including
 * the trailing tokens that share it — matching the fork's `exceedsMaxLineLength`
 * rather than the renderer's local per-segment `fitsFlat`. So a `.concat(arg)`
 * whose segment line reaches the limit leading-breaks (argument kept flat),
 * while the same chain at a shallower column, or a short argument that fits
 * the `noWrap` rule, stays glued.
 */
@:nullSafety(Strict)
final class HxMethodChainCallParamRestAwareSliceTest extends Test {

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
	});

	public function new(): Void {
		super();
	}

	public function testConcatArgStaysHuggedWhenSegmentFits(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r:Payload = holder.flag != null\n'
			+ '\t\t\t? holder.mainSource.first.filter(SomeUtils.notEmpty)\n\t\t\t\t.map(u -> makeEntry(u.label, u.status == OPEN))\n'
			+ '\t\t\t\t.concat(holder.mainSource.backups.filter(SomeUtils.notEmpty).map(u -> makeEntry(u.label, u.status == OPEN)))\n'
			+ '\t\t\t: null;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testShortConcatArgStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal result = holder.mainSource.first.filter(SomeUtils.notEmpty)\n'
			+ '\t\t\t.map(u -> makeEntry(u.label, u.status == OPEN))\n\t\t\t.concat(holder.mainSource.backups);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testLongConcatArgStaysGluedWhenSegmentFits(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal result = holder.mainSource.first.filter(SomeUtils.notEmpty)\n'
			+ '\t\t\t.map(u -> makeEntry(u.label, u.status == OPEN))\n'
			+ '\t\t\t.concat(holder.mainSource.backups.filter(SomeUtils.notEmpty).map(u -> makeEntry(u.label, u.status == OPEN)));\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * Genuine leading-break guard: a `.concat(ARG)` segment inside a DOT-BROKEN
	 * chain whose ARG (itself a method chain, totalItemLength > 100) makes the
	 * segment's physical line reach the limit must LEADING-BREAK the argument
	 * onto its own line (kept flat), matching the fork's whole-line
	 * `exceedsMaxLineLength`. Without the rest-aware `IfLineExceeds` swap the
	 * writer HUGS the argument (local `fitsFlat` is blind to the enclosing
	 * context), so this fails on the unfixed writer.
	 */
	public function testConcatArgLeadingBreaksInDotBrokenChain(): Void {
		final config: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
			edited.lineWidth = 140;
			edited.addLineCommentSpace = false;
			edited.alignInlineSwitchCaseBody = true;
			edited.maxConsecutiveBlanks = 2;
			edited.sameLineExpressionElse = SameLinePolicy.SameOnBlock;
			edited.ifBody = BodyPolicy.FitLine;
			edited.forBody = BodyPolicy.FitLine;
			edited.whileBody = BodyPolicy.FitLine;
			edited.functionBody = BodyPolicy.FitLine;
			edited.expressionIfBody = BodyPolicy.Next;
			edited.expressionElseBody = BodyPolicy.Next;
			edited.forPolicy = WhitespacePolicy.Both;
			edited.switchKwLeadingSpace = true;
			edited.beginType = 1;
			edited.endType = 1;
			edited.abstractBeginType = 1;
			edited.abstractEndType = 1;
			edited.interfaceBeginType = 1;
			edited.interfaceEndType = 1;
			edited.afterLeftCurly = KeepEmptyLinesPolicy.Keep;
			edited.beforeRightCurly = KeepEmptyLinesPolicy.Keep;
			edited.anonTypeBracesOpen = WhitespacePolicy.After;
			edited.anonTypeBracesClose = WhitespacePolicy.Before;
			edited.objectLiteralBracesOpen = WhitespacePolicy.After;
			edited.objectLiteralBracesClose = WhitespacePolicy.Before;
			edited.objectLiteralArrowBodyOpenPad = false;
			edited.comprehensionBracketsOpen = WhitespacePolicy.After;
			edited.comprehensionBracketsClose = WhitespacePolicy.Before;
			edited.ifCondParensInsideClose = WhitespacePolicy.After;
			edited.whileCondParensInsideClose = WhitespacePolicy.After;
			edited.switchCondParensInsideClose = WhitespacePolicy.After;
			edited.catchParensInsideClose = WhitespacePolicy.After;
			edited.sharpCondParensInsideClose = WhitespacePolicy.After;
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
			edited.expressionWrappingWrap = {
				defaultAdditionalIndent: 0,
				defaultMode: WrapMode.FillLineWithLeadingBreak,
				rules: [
					{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
				]
			};
			edited.comprehensionObjectLitGlue = true;
			edited.functionTypeHaxe4 = WhitespacePolicy.None;
			edited.intervalPolicy = WhitespacePolicy.Both;
		});
		final src: String = 'class C {\n\n\tstatic function makeList<T>(actions:Array<Act>):Array<T> {\n'
			+ '\t\treturn [ for (action in actions) {\n\t\t\tfinal a:Payload = {\n\t\t\t\taddItems: holder.mainGroups != null\n'
			+ '\t\t\t\t\t? holder.mainGroups.first.filter(SomeUtils.notEmpty)\n'
			+ '\t\t\t\t\t\t.map(u -> {label: u.label, enabled: u.status == OPEN })\n\t\t\t\t\t\t.concat(\n'
			+ '\t\t\t\t\t\t\tholder.mainGroups.backups.filter(SomeUtils.notEmpty).map(u -> {label: u.label, enabled: u.status == OPEN })\n'
			+ '\t\t\t\t\t\t)\n\t\t\t\t\t: null\n\t\t\t};\n\t\t} ];\n\t}\n\n}';
		final opts: HxModuleWriteOptions = config;
		opts.finalNewline = false;
		Assert.equals(src, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
