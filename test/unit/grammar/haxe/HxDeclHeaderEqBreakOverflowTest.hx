package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.SameLinePolicy;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-N-break-after-eq, decl-header arm: a `var` / `final` declaration whose RHS
 * ALREADY wraps its own call arguments past the open paren, yet whose remaining
 * HEADER line (everything up to and including that open paren) still exceeds
 * `maxLineLength`, breaks after the `=` as a last resort. The existing arms
 * probe the GLUED natural first line, which resolves such a RHS flat and cannot
 * tell an over-wide header from an over-wide one-liner; this arm measures the
 * RHS head — the token run before its first break opportunity — so the break
 * fires only when no amount of RHS-internal wrapping can bring the header back
 * under the limit.
 *
 * Guards: a header EXACTLY on the limit stays glued (strict `>`), and a short
 * header whose full flat line overflows keeps the `=` glued and lets the call
 * arguments wrap (the pre-existing layout).
 *
 * Config is the real `hxformat.json` of the project this shape was found in
 * (tab / tabWidth 4, maxLineLength 140, `callParameter`
 * `fillLineWithLeadingBreak`). Identifiers are synthetic, length-matched to
 * that shape.
 */
@:nullSafety(Strict)
final class HxDeclHeaderEqBreakOverflowTest extends Test {

	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.addLineCommentSpace = false;
		edited.normalizeLineCommentIndent = true;
		edited.alignInlineSwitchCaseBody = true;
		edited.comprehensionCuddledOpen = true;
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

	public function new(): Void {
		super();
	}

	/** Header line is 145 columns even with the call args wrapped -> break after `=`. */
	public function testOverflowingHeaderBreaksAfterEq(): Void {
		final wrapped: String = 'class M {\n\n'
			+ '\tprivate static final recordsIncrementalRemoteRefreshCachePrime:RecordIncrementalRemoteRefreshCache = new '
			+ 'RecordIncrementalRemoteRefreshCache(\n\t\t\'Primes\'\n\t);\n\n}';
		final glued: String = 'class M {\n\n'
			+ '\tprivate static final recordsIncrementalRemoteRefreshCachePrime:RecordIncrementalRemoteRefreshCache = new '
			+ 'RecordIncrementalRemoteRefreshCache(\'Primes\');\n\n}';
		final broken: String = 'class M {\n\n'
			+ '\tprivate static final recordsIncrementalRemoteRefreshCachePrime:RecordIncrementalRemoteRefreshCache =\n'
			+ '\t\tnew RecordIncrementalRemoteRefreshCache(\'Primes\');\n\n}';
		Assert.equals(broken, triviaWrite(wrapped));
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	/** GUARD: header EXACTLY 140 columns -> stays glued, only the call args wrap. */
	public function testHeaderAtLimitStaysGlued(): Void {
		final src: String = 'class M {\n\n\tprivate static final recordsIncrementalRemoteRefreshPrime:RecordIncrementalRemoteRefreshCache '
			+ '= new RecordIncrementalRemoteRefreshCache(\n\t\t\'Primes\'\n\t);\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** GUARD: 51-column header, 144-column flat line -> the call args wrap, `=` stays glued. */
	public function testShortHeaderKeepsEqGlued(): Void {
		final src: String = 'class M {\n\n\tprivate final _badge:BadgeView = new BadgeView(\n'
			+ '\t\tlabel(\'TransparencyLevel\', 207), Typography.getFormatBadgeText(), 64, 20, Colors.PANEL_GREY\n\t);\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** GUARD: a `+` chain's head ends at an OPERAND, not an open delimiter — the chain wraps its own later lines, `=` stays glued. */
	public function testOperatorChainHeadKeepsEqGlued(): Void {
		final src: String = 'class C {\n\n\tfunction f() {\n\t\tfinal request:String = \'SELECT filepath, folder, cloud_id, '
			+ 'folder_cloud_id, action, filepath_movedfrom, filepath_movedfromorigin, tstamp \'\n'
			+ '\t\t\t+ \'FROM files WHERE SUBSTR(filepath, 0, 12) = quoted ORDER by filepath\';\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * A `+` chain whose FIRST operand is a call DOES end at an open delimiter, so the
	 * arm fires: the 145-column head is a real over-wide line and every break point the
	 * chain owns sits past it. Companion to the operand-headed chain above — the two
	 * together pin what `endsAtOpenDelim` does and does not exclude.
	 */
	public function testCallLedChainHeadBreaksAfterEq(): Void {
		final src: String = 'class C {\n\n\tfunction f() {\n\t\tfinal request:String = '
			+ 'buildIncrementalFetchUpdatesRequestForMovedFromPrefixWithQuotedSeparatorAndOrderedFilepathTailSegmentForFetchSync(\'SELECT '
			+ 'filepath, folder, cloud_id, action, tstamp \')\n\t\t\t+ \'FROM files WHERE prefix ORDER by filepath\';\n\t}\n\n}';
		final broken: String = 'class C {\n\n\tfunction f() {\n\t\tfinal request:String =\n'
			+ '\t\t\tbuildIncrementalFetchUpdatesRequestForMovedFromPrefixWithQuotedSeparatorAndOrderedFilepathTailSegmentForFetchSync(\n'
			+ '\t\t\t\t\t\'SELECT filepath, folder, cloud_id, action, tstamp \'\n'
			+ '\t\t\t\t) + \'FROM files WHERE prefix ORDER by filepath\';\n\t}\n\n}';
		Assert.equals(broken, triviaWrite(src));
		Assert.equals(broken, triviaWrite(broken));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
