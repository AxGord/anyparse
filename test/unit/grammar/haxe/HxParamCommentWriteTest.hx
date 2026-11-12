package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Format-mode tests for a block comment sitting between the separator and the
 * following function parameter (`f(a, /* c *\/ b)`). Such a comment is a
 * commented-out parameter run; the separator must stay BEFORE it. The writer's
 * sep-Star cascade used to bake the captured trailing comment into the prior
 * item's Doc, so `WrapList.emit` inserted the comma AFTER it and the comma
 * jumped past the comment (`a /* c *\/, b`). Identifiers are synthetic.
 */
@:nullSafety(Strict)
final class HxParamCommentWriteTest extends Test {

	private static final CFG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
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

	public function new(): Void {
		super();
	}

	/** The reported bug: a lone post-comma block comment must keep the comma before it, inline. */
	public function testPostSepBlockCommentKeepsCommaBefore(): Void {
		Assert.equals(
			'class C {\n\n\tfunction foo(a:Int, /* c */ b:Int):Void {}\n\n}',
			fmt('class C {\n\tfunction foo(a:Int, /* c */ b:Int):Void {}\n}')
		);
	}

	/** Same, on a middle parameter followed by another param. */
	public function testPostSepBlockCommentMiddleParam(): Void {
		Assert.equals(
			'class C {\n\n\tfunction foo(a:Int, /* c */ b:Int, d:Int):Void {}\n\n}',
			fmt('class C {\n\tfunction foo(a:Int, /* c */ b:Int, d:Int):Void {}\n}')
		);
	}

	/** Guard: a comment already BEFORE the comma stays before it (must not regress). */
	public function testPreSepBlockCommentStaysBeforeComma(): Void {
		Assert.equals(
			'class C {\n\n\tfunction foo(a:Int /* c */, b:Int):Void {}\n\n}',
			fmt('class C {\n\tfunction foo(a:Int /* c */, b:Int):Void {}\n}')
		);
	}

	private inline function fmt(src: String): String {
		return HxWriteFixture.triviaWrite(src, CFG);
	}

}
