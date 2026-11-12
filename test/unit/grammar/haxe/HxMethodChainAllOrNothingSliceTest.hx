package unit.grammar.haxe;

import anyparse.core.Doc;
import anyparse.format.BodyPolicy;
import anyparse.format.CommentStyle;
import anyparse.format.SameLinePolicy;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.MethodChainEmit;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapList;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * omega-methodchain-all-or-nothing: a method chain is laid out as ONE unit.
 * The width decision is taken at the column where the HEAD (the chain
 * receiver) actually ENDS -- not at the column where the whole chain starts --
 * and it covers the ENTIRE segment tail plus whatever trails it on the same
 * rendered line. Fits: every link stays glued, on one line, even when the head
 * itself rendered multi-line. Does not fit: EVERY link goes onto its own
 * continuation line and the head line carries NO glued link.
 *
 * That replaces the previous `onePerLineAfterFirst` default, whose two defects
 * this class pins: a head measured FLAT (so a chain riding a multi-line call's
 * closing paren broke although its tail had a whole line free), and a first
 * link glued to the head with no re-probe of the resulting head width (so an
 * over-wide head kept the link and overflowed `maxLineLength`).
 *
 * Config is the client's real `hxformat.json` verbatim (minified). The compiled
 * defaults are config-blind to it -- `maxLineLength` 140, tab indent,
 * `callParameter` fillLineWithLeadingBreak and `methodChainCuddledLinks` all
 * participate in every fixture below, and none of them is a compiled default.
 *
 * Fixtures are length-preserving anonymizations of real call sites; identifier
 * and string lengths carry the layout, their content does not.
 */
@:nullSafety(Strict)
@:access(anyparse.format.wrap.MethodChainEmit)
@:access(anyparse.format.wrap.WrapList)
final class HxMethodChainAllOrNothingSliceTest extends Test {

	/** the client's `hxformat.json`, minified. */
	private static final CFG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.commentStyle = CommentStyle.Javadoc;
		edited.addLineCommentSpace = false;
		edited.normalizeLineCommentIndent = true;
		edited.alignInlineSwitchCaseBody = true;
		edited.comprehensionCuddledOpen = true;
		edited.methodChainCuddledLinks = true;
		edited.sameLineExpressionElse = SameLinePolicy.SameOnBlock;
		edited.ifBody = BodyPolicy.FitLine;
		edited.forBody = BodyPolicy.FitLine;
		edited.whileBody = BodyPolicy.FitLine;
		edited.caseBody = BodyPolicy.FitLine;
		edited.functionBody = BodyPolicy.FitLine;
		edited.expressionIfBody = BodyPolicy.Next;
		edited.expressionElseBody = BodyPolicy.Next;
		edited.forPolicy = WhitespacePolicy.Both;
		edited.switchKwLeadingSpace = true;
		edited.expressionIfArrowBodyReflow = true;
		edited.elseIfCommentReflow = true;
		edited.beginType = 1;
		edited.endType = 1;
		edited.abstractBeginType = 1;
		edited.abstractEndType = 1;
		edited.interfaceBeginType = 1;
		edited.interfaceEndType = 1;
		edited.uniformStatementBlanks = UniformStatementBlanksPolicy.Collapse;
		edited.anonTypeBracesOpen = WhitespacePolicy.After;
		edited.anonTypeBracesClose = WhitespacePolicy.Before;
		edited.objectLiteralBracesOpen = WhitespacePolicy.After;
		edited.objectLiteralBracesClose = WhitespacePolicy.Before;
		edited.objectLiteralArrowBodyReflow = true;
		edited.dropSingleStmtBraces = true;
		edited.singleStmtBraceSymmetry = true;
		edited.dropSwitchSubjectParens = true;
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

	/** A chain riding the closing paren of a head whose own arguments wrapped; the tail has 88 free columns. */
	private static final MULTILINE_HEAD_SRC: String = 'class HintNoticeAlertPopup {\n\n\tprivate function buildBody():Void {\n'
		+ '\t\tfinal lines:Array<String> = t(\n\t\t\t\'<b>Reference Mark</b> have not been supplied with this '
		+ 'schedule.<br><br>Press the Reference Mark badge <b>illuminate</b> on the top toolbar.\',\n\t\t\t205\n'
		+ '\t\t).split(\'<br>\')\n\t\t\t.filter(s -> s.trim() != \'\');\n\t}\n\n}';

	/** Same chain, all-or-nothing: the whole tail glues onto the head's closing line. */
	private static final MULTILINE_HEAD_EXP: String = 'class HintNoticeAlertPopup {\n\n\tprivate function buildBody():Void {\n'
		+ '\t\tfinal lines:Array<String> = t(\n\t\t\t\'<b>Reference Mark</b> have not been supplied with this '
		+ 'schedule.<br><br>Press the Reference Mark badge <b>illuminate</b> on the top toolbar.\',\n\t\t\t205\n'
		+ '\t\t).split(\'<br>\').filter(s -> s.trim() != \'\');\n\t}\n\n}';

	/** The 151-column regression: the link stayed glued to a 130-column head and only its ARGUMENT wrapped. */
	private static final OVERWIDE_HEAD_SRC: String = 'class RemoveItemAlert extends HaltAlert {\n\n'
		+ '\tpublic function new(removeEvent:CatalogBlockEvent) {\n\t\tsuper(\n'
		+ '\t\t\tt(\'Remove\', 31),\n\t\t\tt(\'Are you sure you want to remove item '
		+ '<b>{value}</b>? This will cause a problem with catalog listing for this '
		+ 'ite.\').findAndReplaceValue(\n\t\t\t\tremoveEvent.userEmail\n\t\t\t)\n\t\t);\n\t}\n\n}';

	/** Same call, all-or-nothing: head line 130 columns, the single link on its own continuation line. */
	private static final OVERWIDE_HEAD_EXP: String = 'class RemoveItemAlert extends HaltAlert {\n\n'
		+ '\tpublic function new(removeEvent:CatalogBlockEvent) {\n\t\tsuper(\n\t\t\tt(\'Remove\', 31),\n'
		+ '\t\t\tt(\'Are you sure you want to remove item <b>{value}</b>? This will cause a problem with catalog listing for this ite.\')\n'
		+ '\t\t\t\t.findAndReplaceValue(removeEvent.userEmail)\n\t\t);\n\t}\n\n}';

	/** A three-link chain 152 columns wide flat. */
	private static final LONG_CHAIN_SRC: String = 'class LongChainSample {\n\n\tprivate function run():Void {\n\t\tfinal outcome:String = '
		+ 'fetchRecords(sourceHandle).mapEachEntry(entryMapperFn).filterOutEmpty(predicateHandle).joinWithComma(separatorValueName);\n\t}\n'
		+ '\n}';

	/** Same chain broken: the head line ends at the receiver, every link on its own continuation line. */
	private static final LONG_CHAIN_EXP: String = 'class LongChainSample {\n\n\tprivate function run():Void {\n'
		+ '\t\tfinal outcome:String = fetchRecords(sourceHandle)\n\t\t\t.mapEachEntry(entryMapperFn)\n'
		+ '\t\t\t.filterOutEmpty(predicateHandle)\n\t\t\t.joinWithComma(separatorValueName);\n\t}\n\n}';

	/** CONTROL: a two-link chain that fits (104 columns) -- byte-inert under the policy. */
	private static final SHORT_CHAIN: String = 'class ShortChainSample {\n\n\tprivate function run():Void {\n'
		+ '\t\tfinal joined:String = fetchRecords(sourceHandle).mapEachEntry(entryMapperFn).joinWithComma(sep);\n\t}\n\n}';

	/** A broken chain whose last link follows a multi-line lambda argument's closing brace. */
	private static final CUDDLE_SRC: String = 'class CuddleSample {\n\n\tprivate function run():Void {\n'
		+ '\t\tremoteClient.second(plainArgumentValueName).third(anotherPlainArgumentValueName).fourth((r:ResponsePayload) -> {\n'
		+ '\t\t\thandleResult(r);\n\t\t}).fifth(yetAnotherPlainArgumentValue);\n\t}\n\n}';

	/** A chain whose head is a bare IDENT, wide enough (161 columns flat) that the tail cannot fit after it. */
	private static final IDENT_HEAD_SRC: String = 'class TweenSample {\n\n\tprivate function run():Void {\n'
		+ '\t\tActuate.tween(_progressBarShape, TRANSITION_DURATION, { x: 0, alpha: 1 '
		+ '}).ease(Quad.easeInOut).onUpdate(progressUpdateHandler).onComplete(finishHandler);\n\t}\n\n}';

	/** Same chain: `.tween(...)`'s dot follows `Actuate`, not a `)`, so it is not a chain item and stays with the head. */
	private static final IDENT_HEAD_EXP: String = 'class TweenSample {\n\n\tprivate function run():Void {\n'
		+ '\t\tActuate.tween(_progressBarShape, TRANSITION_DURATION, { x: 0, alpha: 1 })\n\t\t\t.ease(Quad.easeInOut)\n'
		+ '\t\t\t.onUpdate(progressUpdateHandler)\n\t\t\t.onComplete(finishHandler);\n\t}\n\n}';

	public function new(): Void {
		super();
	}

	/**
	 * DISCRIMINATES: the head renders multi-line, so the tail starts at column
	 * 9 and fits with room to spare. Read FLAT (the pre-slice probe) the
	 * chain is far over the limit and dot-breaks.
	 */
	public function testTailGluesOntoAMultilineHeadsClosingLine(): Void {
		Assert.equals(MULTILINE_HEAD_EXP, triviaWrite(MULTILINE_HEAD_SRC));
	}

	/**
	 * DISCRIMINATES: head 130 + link 43 = 173 columns, so the chain breaks and
	 * the head line comes in at 130. Pre-slice the link glued to the head and
	 * wrapped its own argument instead, emitting a 151-column line at a limit
	 * of 140 -- the head width was never re-probed after the glue.
	 */
	public function testOverwideHeadDropsTheLinkInsteadOfWrappingItsArgument(): Void {
		Assert.equals(OVERWIDE_HEAD_EXP, triviaWrite(OVERWIDE_HEAD_SRC));
	}

	/** DISCRIMINATES: all-or-nothing under a CALL head -- no link rides the head line, all three break. */
	public function testBrokenChainLeavesTheHeadLineBare(): Void {
		Assert.equals(LONG_CHAIN_EXP, triviaWrite(LONG_CHAIN_SRC));
	}

	/** CONTROL: a fitting chain is untouched. */
	public function testFittingChainStaysOnOneLine(): Void {
		Assert.equals(SHORT_CHAIN, triviaWrite(SHORT_CHAIN));
	}

	/**
	 * CONTROL for `wrapping.methodChainCuddledLinks`: a link following a
	 * multi-line lambda argument's `})` still rides that closing line, and the
	 * broken chain still leaves the head line bare.
	 */
	public function testLambdaCloserCuddleSurvivesTheAllOrNothingBreak(): Void {
		final out: String = triviaWrite(CUDDLE_SRC);
		Assert.isTrue(out.indexOf('}).fifth(') != -1, 'expected the link after the lambda closer to stay cuddled: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.third(') != -1, 'expected every chain item on its own line: <$out>');
	}

	/**
	 * The isDotAfterPClose half of the policy: a `.` is a chain item only when it
	 * follows a `)`. This chain's head is the bare ident `Actuate`, so
	 * `.tween(...)` is not a chain item — it belongs to the head and stays glued,
	 * and only the three links after a `)` break. Without the refinement the head
	 * line is the two-token `Actuate` alone, which reads worse than the glued head
	 * the policy set out to fix.
	 */
	public function testIdentHeadKeepsItsFirstLinkGlued(): Void {
		Assert.equals(IDENT_HEAD_EXP, triviaWrite(IDENT_HEAD_SRC));
	}

	/** Every broken shape is a fixed point of the writer. */
	public function testBrokenShapesAreIdempotent(): Void {
		Assert.equals(MULTILINE_HEAD_EXP, triviaWrite(MULTILINE_HEAD_EXP));
		Assert.equals(OVERWIDE_HEAD_EXP, triviaWrite(OVERWIDE_HEAD_EXP));
		Assert.equals(LONG_CHAIN_EXP, triviaWrite(LONG_CHAIN_EXP));
		Assert.equals(IDENT_HEAD_EXP, triviaWrite(IDENT_HEAD_EXP));
	}

	/**
	 * Structural pin for the reader coupling this slice moves: `emit` now nests
	 * its width decision one `Concat` child in (`Concat([receiver, tail])`), and
	 * `WrapList.isMethodChainItem` — the refusal gate two call-arg glue paths
	 * consult — reads that decision positionally. It must recognise EVERY shape
	 * `emit` can produce, or a chain argument silently starts taking a glue path
	 * written to refuse chains. Nothing in the writer's own output pins this:
	 * the consumers' other gates masked all five shapes in the corpora, so the
	 * regression was invisible until the walker was probed directly.
	 */
	public function testEveryEmittedChainShapeReadsAsAChainItem(): Void {
		final opt: HxModuleWriteOptions = CFG;
		for (named in chainCascades()) {
			final doc: Doc = MethodChainEmit.emit(Text('recv'), chainSegments(), opt, named.rules, false, named.leadingBreak);
			Assert.isTrue(WrapList.isMethodChainItem(doc), 'chain shape "${named.name}" must read as a method-chain item');
		}
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CFG);
	}

	/**
	 * The five cascades that reach `emit`'s five distinct return shapes: a
	 * collapsed cascade (both `evalAt` states agree) in each break mode, a split
	 * cascade (`IfFullLineExceeds`), the same split tagged for the re-glue
	 * (`CollapseChainProbe`, which needs a leading-break segment call), and a
	 * non-`lineWidth` `LineLengthLargerThan` threshold (`IfWidthExceeds` tree).
	 */
	private function chainCascades(): Array<{ name: String, rules: WrapRules, leadingBreak: Bool }> {
		final splitRules: WrapRules = {
			rules: [
				{ mode: WrapMode.NoWrap, conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }] }
			],
			defaultMode: WrapMode.OnePerLine
		};
		return [
			{ name: 'collapsed onePerLine', rules: { rules: [], defaultMode: WrapMode.OnePerLine }, leadingBreak: false },
			{
				name: 'collapsed onePerLineAfterFirst',
				rules: { rules: [], defaultMode: WrapMode.OnePerLineAfterFirst },
				leadingBreak: false
			},
			{ name: 'split cascade', rules: splitRules, leadingBreak: false },
			{ name: 'split cascade, re-glue tagged', rules: splitRules, leadingBreak: true },
			{
				name: 'extra threshold',
				rules: {
					rules: [
						{ mode: WrapMode.OnePerLine, conditions: [{ cond: WrapConditionType.LineLengthLargerThan, value: 160 }] },
						{ mode: WrapMode.NoWrap, conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }] }
					],
					defaultMode: WrapMode.OnePerLine
				},
				leadingBreak: false
			}
		];
	}

	/** Two call segments — enough for every shape, and the last one opens a call so the re-glue tag can apply. */
	private function chainSegments(): Array<Doc> {
		return [
			Concat([Text('.first('), Text('alpha'), Text(')')]),
			Concat([Text('.second('), Text('beta'), Text(')')])
		];
	}

}
