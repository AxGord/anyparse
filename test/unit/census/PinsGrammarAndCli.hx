package unit.census;

/**
 * Part of the pin census `unit.PinCensusParityTest` compares with `TestRegistry.pins()`:
 * the pins from `'unit.cli.'` up to `'unit.query.'`: `unit.cli`, `unit.core`, `unit.format`,
 * `unit.grammar` (with `unit.grammar.haxe`) and `unit.lowering`
 *
 * SORTED, in code-unit order (`TestRegistry.pins()` sorts so): a new pin goes into the part
 * whose range holds it, at its sorted place — `hxq add-element test/unit/census/PinsGrammarAndCli.hx --sorted
 * --select 'FinalMember:PINS >> ArrayExpr' "'<entry>'" --write`. The parts concatenate in
 * range order, so an entry in the wrong part fails the census as a misordered list.
 */
@:nullSafety(Strict)
final class PinsGrammarAndCli {

	public static final PINS: Array<String> = [
		'unit.cli.AddressCliTest#testRemoveElementKindLift :: control :: M-REMOVE-ELEMENT-KIND-IGNORED',
		'unit.cli.AddressCliTest#testRemoveElementReportFollowsKeepDoc :: control :: M-REMOVE-CUT-ANNOTATIONS-NONE',
		'unit.cli.AddressCliTest#testRemoveElementReportNamesWhatTheCutTook :: control :: M-REMOVE-CUT-ANNOTATIONS-NONE',
		'unit.cli.AddressCliTest#testRemoveElementReportOnAModifierPositionNamesTheDeclaration :: control :: M-REMOVE-CUT-SUBJECT-RAW',
		'unit.cli.ApqBatchQueryCliTest#testTheSeparatorIsWhatSplitsQueriesFromScope :: control :: M-BATCH-SEPARATOR-BLIND',
		'unit.cli.ApqDxTier5CliTest#testProbeRefusesToStageOntoASymlink :: guard :: ',
		'unit.cli.ApqDxTier5CliTest#testProbeRestagingOverwritesPreviousScratch :: control :: M-PROBE-SLOT-CONST',
		'unit.cli.ApqDxTier5CliTest#testProbeStagesSourceUnderTheCurrentTempRoot :: control :: M-PROBE-SLOT-CONST',
		'unit.cli.ApqDxTier5CliTest#testProbeStagingRefusesANonRegularTargetAndHonoursTheEnvPath :: control :: M-PROBE-STAGE-ANY-TARGET',
		'unit.cli.ApqDxTier5CliTest#testTwoProbeProcessesGetSeparateScratchSlots :: guard :: ',
		'unit.cli.ApqDxTier5CliTest#testTwoProbeProcessesUnderOneTempRootStillGetSeparateSlots :: guard :: ',
		'unit.cli.ApqKindVocabularyCliTest#testAProjectedKindStillRuns :: guard :: ',
		'unit.cli.ApqKindVocabularyCliTest#testAstSelectMissKeepsTheCrossProjectPointer :: control :: M-AST-SELECT-NO-CROSS-PROJECT-HINT',
		'unit.cli.ApqKindVocabularyCliTest#testAstSelectProjectedButAbsentKindStaysOk :: guard :: ',
		'unit.cli.ApqKindVocabularyCliTest#testAstSelectUnprojectedKindIsAUsageError :: control :: M-AST-SELECT-UNKNOWN-KIND-EXIT-OK',
		'unit.cli.ApqKindVocabularyCliTest#testLitAcceptsTheKindsItMintsItself :: control :: M-LIT-SYNTHETIC-KINDS-EMPTY',
		'unit.cli.ApqKindVocabularyCliTest#testLitRejectsAnUnprojectedKind :: control :: M-KIND-GATE-FAIL-OPEN',
		'unit.cli.ApqMentionsImportCliTest#testSimpleNameAnswersTheDottedImport :: control :: M-MENTIONS-IMPORT-KINDS-UNPASSED',
		'unit.cli.ApqMentionsImportCliTest#testSimpleNameAnswersTheDottedUsing :: control :: M-LIT-QUALIFIED-KINDS-IGNORED',
		'unit.cli.ApqProgressTtyCliTest#testNoEnvAndNoTerminalIsSilent :: control :: M-PROGRESS-TTY-BLIND',
		'unit.cli.ApqScratchPathCliTest#testStdlibDupRefusesAWorkDirectoryThatIsASymlink :: control :: M-STDLIB-DUP-WORK-ANY-TARGET',
		'unit.cli.ApqScratchPathCliTest#testStdlibDupStagesItsProbesInAPerProcessDirectory :: control :: M-STDLIB-DUP-WORKDIR-SHARED',
		'unit.cli.ApqScratchPathCliTest#testTestSummaryReadsTheTranscriptTheEnvVarNames :: control :: M-TEST-SUMMARY-GLOBAL-DEFAULT',
		'unit.cli.ApqScratchPathCliTest#testTestSummaryWithoutASourceOrTheEnvVarIsAUsageError :: control :: M-TEST-SUMMARY-GLOBAL-DEFAULT',
		'unit.cli.ApqScratchPathCliTest#testThreeTestSummaryProcessesUnderOneTempRootEachAnswerFromTheirOwnSource :: guard :: ',
		'unit.cli.ApqScratchPathCliTest#testTwoStdlibDupProcessesUnderOneTempRootGetSeparateWorkDirectories :: guard :: ',
		'unit.cli.ApqSourceReadGuardCliTest#testALongUnnarrowedReadIsRefused :: control :: M-SOURCE-READ-GUARD-OFF',
		'unit.cli.ApqTestSummaryExitStatusCliTest#testTruncatedTranscriptDisagreesWithANonZeroExit :: control :: M-EXIT-STATUS-AGREES',
		'unit.cli.CliCommandSeamTest#testTheRegistryHandsOutAFreshCommandPerCall :: control :: M-CLI-COMMANDS-MEMOISED',
		'unit.cli.CliCommandSeamTest#testTheRequireMatchFlagDoesNotSurviveItsRun :: control :: M-CLI-REQUIREMATCH-STATIC',
		'unit.cli.CliUnknownSubcommandTest#testAPluralMissNamesTheSingularCommands :: control :: M-CLI-UNKNOWN-NO-PLURAL-PROBE',
		'unit.cli.ExtractConstantToCliTest#testTheAddressedModeWritesTheSourceAndTheModule :: control :: '
			+ 'M-EXTRACT-CONSTANT-ADDRESSED-UNROUTED',
		'unit.cli.JsonEditCliTest#testAfterTheSoleEntryOfAnArray :: control :: M-COMMA-CONTAINER-KINDS-UNREAD',
		'unit.cli.JsonEditCliTest#testAppendIntoAnArray :: control :: M-LAYOUT-SPLICE-BYPASSED,M-PICK-PLUGIN-FOR-IGNORES-PATH',
		'unit.cli.JsonEditCliTest#testSortedInsert :: control :: M-JSON-LITERAL-NONE',
		'unit.cli.LintConfigCliTest#testTheScopeGapNoticesReachTheRun :: control :: M-SCOPE-GAP-UNWIRED,M-SCOPE-GAP-ROOT-UNWIRED',
		'unit.cli.LintExplainLongCliTest#testAFindingNamingNoFileIsPrinted :: control :: M-LINT-NOFILE-DROPPED',
		'unit.cli.LintExplainLongCliTest#testAnErrorPathReasonNamesItsCatch :: control :: M-LINT-FORMAT-ERRORPATH',
		'unit.cli.LintExplainLongCliTest#testDominatedLocksAreNamed :: control :: M-LINT-FORMAT-DOMINATED',
		'unit.cli.LintExplainLongCliTest#testJsonEnvelopeCarriesFindingsAndLongLocks :: control :: M-LINT-EXPLAIN-UNSET',
		'unit.cli.LintExplainLongCliTest#testNothingToExplainIsSaid :: control :: M-LINT-EXPLAIN-NO-ENVELOPE',
		'unit.cli.LintFixFactsSettleTest#testTheFactsSettleBeforeTheFirstWrite :: control :: M-FIX-FACTS-SETTLED',
		'unit.cli.LintFixQuietDefaultTest#testTheRuleAccountingWaitsForAnEditOrForVerbose :: control :: M-LINT-FIX-CENSUS-UNGATED',
		'unit.cli.LintFixRemoveTest#testAPassPutsAnAmbientSourceItRewroteOnDisk :: control :: M-FIX-AMBIENT-HELD',
		'unit.cli.LintFixRemoveTest#testARemoveDeletesTheFile :: control :: M-FIX-REMOVE-IGNORED',
		'unit.cli.LintFixRemoveTest#testARevertRestoresADeletedFileByteForByte :: control :: M-FIX-REMOVE-NO-RESTORE',
		'unit.cli.LintFixRemoveTest#testOverlappingCrossFileEditsAreSkipped :: control :: M-FIX-OVERLAP-BLIND',
		'unit.cli.LintQuotationAwareCliTest#testAQuotedRedundantParensFindingIsFixed :: control :: M-PARENS-QUOTED-DROPPED',
		'unit.cli.LintQuotationAwareCliTest#testAQuotedRedundantParensFindingReports :: control :: M-PARENS-QUOTED-DROPPED',
		'unit.cli.LintRangeCliTest#testACommentOnlyWriteAppliesNoFix :: control :: M-POST-WRITE-FIX-TRIVIA-BLIND',
		'unit.cli.LintRangeCliTest#testADiffPastItsBudgetGivesNoWindowsAtAll :: control :: M-POST-WRITE-FIX-FAIL-OPEN',
		'unit.cli.LintRangeCliTest#testAnOddCommentOnlyWriteAcrossTwoRegionsAppliesNoFix :: control :: M-POST-WRITE-FIX-HULL',
		'unit.cli.LintRangeCliTest#testWriteFixLeavesAStandingFindingOutsideTheWindow :: control :: M-LINT-RANGE-INERT',
		'unit.cli.LintRangeCliTest#testWriteFixLintsEachChangedRegionAndNotTheCodeBetween :: control :: M-POST-WRITE-FIX-HULL',
		'unit.cli.MoveElementsCliTest#testTheDryRunPrintsTheDigestAndWritesNothing :: control :: M-MOVE-ELEMENTS-DRY-RUN-UNROUTED',
		'unit.cli.ResolutionScopeCliTest#testCrossingSuperNeedsRootsThatMatch :: control :: M-FIAD-ROOTS-MATCH-IGNORED',
		'unit.core.BreakCommitsReplacedTest#testAnUntouchedSiblingIsShared :: control :: M-OFFER-COPIES-WHOLE',
		'unit.core.BreakCommitsReplacedTest#testAnotherBreaksAlternativeIsLeftAlone :: control :: M-OFFER-REPLACES-BOTH-SIDES',
		'unit.core.RendererParenSiblingRestTest#testAParenOnAnUnresolvedFlatSideIsNoBreakPoint :: control :: M-PAREN-ALT-ROUTE',
		'unit.core.RendererParenSiblingRestTest#testAProbeInAForceFlatFrameIsNoBreakPoint :: control :: M-PAREN-SIBLING-FORCE-FLAT-FRAME',
		'unit.core.RendererParenSiblingRestTest#testARunOnBreakRouteWidensTheLine :: control :: M-PAREN-ALT-SURPLUS',
		'unit.core.RendererParenSiblingRestTest#testARunOnRouteSuspendsPredictionsInsideItsNode :: control :: M-PAREN-RUNON-SUSPEND',
		'unit.core.RendererParenSiblingRestTest#testASoftBreakUnderABoundaryInsideFlattenIsNotMeasured :: control :: '
			+ 'M-PAREN-EXACT-SOFT-BOUNDARY',
		'unit.core.RendererParenSiblingRestTest#testASuspensionEndsWithItsFrame :: control :: M-PAREN-RUNON-FRAME',
		'unit.core.RendererParenSiblingRestTest#testASuspensionEndsWithTheNodeItCovers :: control :: M-PAREN-RUNON-RESUME',
		'unit.core.RendererParenSiblingRestTest#testAnUnboundedBreakSideTakesTheWalkOffThePath :: control :: M-PAREN-SIBLING-OFF-PATH',
		'unit.core.RendererParenSiblingRestTest#testConsecutiveHeldBackSpacesAllStayOutOfTheColumn :: control :: '
			+ 'M-PAREN-PENDING-LAST-ONLY',
		'unit.core.RendererSharedDocTest#testProbeSearchVisitsASharedNodeOnce :: control :: M-PROBE-SEARCH-REVISITS',
		'unit.dev.ScrubGuardTest#testAPathOfAPrivateTreeIsAMatch :: control :: M-SCRUB-PRIVATE-PATH-BLIND',
		'unit.format.BraceSymmetrySliceTest#testAWrappedValueThenBranchDropsItsSourceSemicolon :: control :: M-SSB-VALUE-WRAP-OFF',
		'unit.format.BraceSymmetrySliceTest#testTheSameTryOutsideAMacroIsStillBraced :: control :: M-TRY-BODY-SYM-OFF,M-SSB-TRY-SUBST-OFF',
		'unit.format.BraceSymmetrySliceTest#testTheSemicolonDropAlsoHoldsUnderExpressionIfNext :: control :: M-SSB-VALUE-WRAP-OFF',
		'unit.format.BraceSymmetrySliceTest#testTheStatementAndValueSkipListsAgree :: control :: M-SSB-VALUE-WRAP-OFF',
		'unit.format.BraceSymmetrySliceTest#testThenBareElseBracedGainsBraces :: control :: M-SSB-SYMMETRY-ONLY-BLIND',
		'unit.format.BraceSymmetrySliceTest#testThenBracedElseBareGainsBraces :: control :: M-SSB-SYMMETRY-ONLY-BLIND',
		'unit.format.CommentDirectiveTest#testDirectivesAreRecognised :: control :: M-COMMENT-DIRECTIVE-NONE',
		'unit.format.CommentDirectiveTest#testOnlyAPlainLineCommentIsRelocatable :: control :: M-TCO-DIRECTIVE-MOVED',
		'unit.format.WrapFlatSourceFixedPointTest#testCommittedLiteralUnderAChainOrArrowSettlesInOneWrite :: control :: M-COLLAPSE-COUNTED',
		'unit.format.WrapFlatSourceFixedPointTest#testFitPivotArgumentKeepsItsOpenCall :: control :: M-NAMED-FIT-PIVOT',
		'unit.format.WrapFlatSourceFixedPointTest#testNestedNamedBreaksWriteInPolynomialTime :: control :: M-OFFER-REPLACED-COPIES',
		'unit.format.WrapFlatSourceFixedPointTest#testNestedPivotCallArgPacksOnPassOne :: control :: M-THRESHOLD-ARG-UNNAMED',
		'unit.format.WrapFlatSourceFixedPointTest#testPivotArgUnderATernaryBreaksTheTernaryOnPassOne :: control :: M-CHAIN-OFFER-OFF',
		'unit.format.WrapFlatSourceFixedPointTest#testPivotCaseUnitDoesNotLeadTheSiblingSpread :: control :: M-SIBLING-OFFER-UNALIASED',
		'unit.format.WrapFlatSourceFixedPointTest#testSoleUncommittedObjectLiteralArgKeepsTheOpenParen :: control :: M-COLLAPSE-ANY-RESULT',
		'unit.grammar.JsonKeyMetaCompileTest#testAKeyMustBeOneString :: control :: M-JSON-KEY-UNCHECKED',
		'unit.grammar.JsonKeyMetaCompileTest#testAKeyMustBeWritableAsIs :: control :: M-JSON-KEY-UNWRITABLE',
		'unit.grammar.JsonKeyMetaCompileTest#testTwoFieldsCannotShareAKey :: control :: M-JSON-KEY-DUPLICATES,M-JSON-KEY-DUP-AT-FIELD',
		'unit.grammar.JsonLayoutWriterTest#testACrlfDocumentGetsCrlfLines :: control :: M-JSON-LINE-END-LF',
		'unit.grammar.JsonLayoutWriterTest#testADeletionClosesItsGap :: control :: M-JSON-DIRTY-NEVER',
		'unit.grammar.JsonLayoutWriterTest#testANewMemberTakesItsSiblingsKeySpacing :: control :: M-JSON-KEYSEP-DEFAULT',
		'unit.grammar.JsonLayoutWriterTest#testANewObjectTakesItsSiblingsShape :: control :: M-JSON-NEW-MODEL-IGNORED,M-JSON-NOTHING-NEW',
		'unit.grammar.JsonLayoutWriterTest#testAnEmptyContainerFollowsItsParent :: control :: M-JSON-EMPTY-INLINE,M-JSON-TOUCH-IGNORED',
		'unit.grammar.JsonLayoutWriterTest#testAnInlineArrayStaysInline :: control :: M-JSON-STYLE-ALWAYS-EXPANDED',
		'unit.grammar.JsonLayoutWriterTest#testTheIndentUnitIsTheDocuments :: control :: M-JSON-INDENT-DEFAULT',
		'unit.grammar.JsonLayoutWriterTest#testTheSecondEditsFootprintIsShifted :: control :: M-JSON-MARKS-UNSHIFTED',
		'unit.grammar.JsonLayoutWriterTest#testWritingWithNoEditKeepsEveryByte :: control :: M-JSON-ROOT-UNTIGHTENED',
		'unit.grammar.JsonTypedParserTest#testDeclaredKeyIsTheParsedKey :: control :: M-JSON-KEY-PARSE',
		'unit.grammar.JsonTypedParserTest#testDeclaredKeyIsTheWrittenKey :: control :: M-JSON-KEY-WRITE',
		'unit.grammar.MermaidParserTest#testADottedLabelStopsBeforeItsClosingDots :: control :: M-MERMAID-DOTTED-TEXT-TAKES-DOTS',
		'unit.grammar.MermaidParserTest#testAPlainAmpersandStaysPlain :: control :: M-MERMAID-PLAIN-AMP-RAW',
		'unit.grammar.MermaidParserTest#testAnInlineLabelWithMarkupParses :: control :: M-MERMAID-INLINE-TAKES-PREFIX',
		'unit.grammar.MermaidParserTest#testAnUndirectedHeaderEndsItsLine :: guard :: ',
		'unit.grammar.MermaidParserTest#testAnyLabelRoundTripsThroughTheWriter :: control :: M-MERMAID-ENCODE-DROPPED',
		'unit.grammar.MermaidParserTest#testWritingKeepsWhatALabelRenders :: control :: '
			+ 'M-MERMAID-PLAIN-LT-RAW,M-MERMAID-PLAIN-AMP-RAW,M-MERMAID-TICK-UNESCAPED,M-MERMAID-NUMERIC-REF-RAW',
		'unit.grammar.MermaidTextTest#testAnInvalidNumericCodeStaysAsWritten :: control :: M-MERMAID-CODEPOINT-UNBOUNDED',
		'unit.grammar.MermaidTextTest#testEveryPlainAmpersandIsACode :: control :: M-MERMAID-PLAIN-AMP-RAW',
		'unit.grammar.MermaidTextTest#testMarkupWritesANumericReferenceAsACode :: control :: M-MERMAID-NUMERIC-REF-RAW',
		'unit.grammar.MermaidTextTest#testPlainBackticksNeverOpenMarkdown :: control :: M-MERMAID-TICK-UNESCAPED',
		'unit.grammar.MermaidTextTest#testPlainMarkupCharactersAreEscaped :: control :: M-MERMAID-PLAIN-LT-RAW,M-MERMAID-PLAIN-AMP-RAW',
		'unit.grammar.MermaidTextTest#testTheCodeAlphabetIsWordCharacters :: control :: M-MERMAID-CODE-ALPHABET-NARROW',
		'unit.grammar.haxe.ComplexItemKindsSeamTest#testTheGeneratedPredicateAnswersTheClassifier :: control :: M-KINDS',
		'unit.grammar.haxe.ComplexItemKindsSeamTest#testTheTriviaFamilyCarriesTheSameEntry :: seam :: ',
		'unit.grammar.haxe.ElseSwitchPlacementSliceTest#testACommentBeforeTheThenSwitchDeclinesBothSeams :: control :: '
			+ 'M-ELSE-SWITCH-CLOSE-COMMENT',
		'unit.grammar.haxe.ElseSwitchPlacementSliceTest#testACommentBetweenElseAndSwitchDeclinesTheGlue :: control :: '
			+ 'M-ELSE-SWITCH-COMMENT-GLUE',
		'unit.grammar.haxe.ElseSwitchPlacementSliceTest#testAnElseIfChainEndingInElseSwitch :: control :: M-ELSE-SWITCH-TESTS-NONE',
		'unit.grammar.haxe.ElseSwitchPlacementSliceTest#testSameGluesTheThenSwitchToItsIfHeadToo :: control :: M-ELSE-SWITCH-CLOSE-NONE',
		'unit.grammar.haxe.ElseSwitchPlacementSliceTest#testSamePlacesTheSwitchOnTheElseLine :: control :: M-ELSE-SWITCH-TESTS-NONE',
		'unit.grammar.haxe.ElseSwitchPlacementSliceTest#testTheValueIfThenBranchGluesAsWell :: control :: M-ELSE-SWITCH-TESTS-NONE',
		'unit.grammar.haxe.HxAnonFieldTypeProjectionTest#testATypeSlotThatIsAlsoAChildPrintsOnce :: control :: M-AST-SLOT-DUPLICATED',
		'unit.grammar.haxe.HxArrowBlockIfOverflowSliceTest#testOverflowingBlockIfBreaksAfterArrow :: control :: M-ARROW-HEAD-WIDTH-NONE',
		'unit.grammar.haxe.HxBinaryChainRestWidthTest#testAddChainOneColumnOverBreaksAtPlus :: control :: M-CHAIN-REST-ADD-PIVOT-PLAIN',
		'unit.grammar.haxe.HxBinaryChainRestWidthTest#testAddChainTwoColumnsOverBreaksAtPlus :: control :: M-COLLAPSE-ADD-REBUILD-PLAIN',
		'unit.grammar.haxe.HxBinaryChainRestWidthTest#testDeclarationOneColumnOverBreaksAtAnd :: control :: '
			+ 'M-CHAIN-REST-FILL-GROUP-PLAIN,M-CHAIN-REST-SHAPE-UNTHREADED,M-CHAIN-REST-UNSET',
		'unit.grammar.haxe.HxBinaryChainRestWidthTest#testDeclarationTwoColumnsOverBreaksAtAnd :: control :: M-CHAIN-REST-PIVOT-PLAIN',
		'unit.grammar.haxe.HxBlankAroundMultilineMembersTest#testBlankAppearsBeforeAMultilineMember :: control :: M-BLANK-MULTILINE-OFF',
		'unit.grammar.haxe.HxBlankAroundMultilineMembersTest#testBlankAppearsBetweenMultilineAndSingleLine :: control :: '
			+ 'M-BLANK-MULTILINE-OFF',
		'unit.grammar.haxe.HxCallArgLambdaBodyChainIndentTest#testArrowSwitchCaseBodyChainIndents :: control :: M-STMT-LIST-CALLARG-CASE',
		'unit.grammar.haxe.HxCallArgLambdaBodyChainIndentTest#testFinalInFirstLambdaArgChainIndents :: control :: '
			+ 'M-STMT-LIST-CALLARG-BLOCK',
		'unit.grammar.haxe.HxCallArgLambdaBodyChainIndentTest#testReturnInSoleLambdaArgChainIndents :: control :: '
			+ 'M-STMT-LIST-CALLARG-BARRIER',
		'unit.grammar.haxe.HxCallArgsTrailingCommaKeepTest#testABrokenCallKeepsItsTrailingComma :: control :: M-CALL-SOURCE-TRAIL-OFF',
		'unit.grammar.haxe.HxCallArgsTrailingCommaKeepTest#testAFlatCallKeepsItsTrailingComma :: control :: M-CALL-FLAT-SOURCE-TRAIL-OFF',
		'unit.grammar.haxe.HxCallGroupRestProbeCasePatternTest#testCasePatternCtorInsideACollectionStaysGlued :: control :: '
			+ 'M-PATTERN-RESTPROBE-UNSET',
		'unit.grammar.haxe.HxCaseBodyControlFlowGlueTest#testABracelessControlFlowBodyGoesBelowAndSpreads :: control :: '
			+ 'M-CASE-CTRLFLOW-STAR-FLAG-BLIND',
		'unit.grammar.haxe.HxCaseBodyControlFlowGlueTest#testAControlFlowBodySpreadsItsSiblings :: control :: '
			+ 'M-CASE-CTRLFLOW-STAR-FLAG-BLIND',
		'unit.grammar.haxe.HxCaseBodyControlFlowGlueTest#testEveryControlFlowCtorGoesBelowItsLabel :: control :: '
			+ 'M-CASE-CTRLFLOW-STAR-FLAG-BLIND',
		'unit.grammar.haxe.HxCaseBodyPolicySliceTest#testDefaultBranchSameFlattensSingleStmt :: control :: M-KWREF-TIGHT-LEAD-BLIND',
		'unit.grammar.haxe.HxChainStaircaseSliceTest#testFiveLinkChainStaircasesAsOneShape :: control :: M-CHAIN-STAIRCASE-OFF',
		'unit.grammar.haxe.HxChainStaircaseSliceTest#testIsIdempotentAcrossThreePasses :: control :: M-CHAIN-STAIRCASE-OFF',
		'unit.grammar.haxe.HxChainStaircaseSliceTest#testTornConditionParenIsGone :: control :: M-CHAIN-STAIRCASE-OFF',
		'unit.grammar.haxe.HxChainStaircaseSliceTest#testWholeChainOverTheLimitStaircases :: control :: M-CHAIN-STAIRCASE-OFF',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testALineEndingBlockCommentKeepsTheCatchOnTheNextLine :: control :: '
			+ 'M-CATCH-BLOCK-LINE-END-GLUED',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testDoWhileKeepsTheKeywordGlued :: control :: M-CLOSE-TRAIL-BLOCK-BREAKS',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testEmptyBlockKeepsTheKeywordGlued :: control :: M-CLOSE-TRAIL-EMPTY-HARD',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testEmptyBlockLineCommentKeepsTheKeywordAtItsIndent :: control :: '
			+ 'M-CLOSE-TRAIL-EMPTY-HARD',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testOpenCommentBlockLineCommentBreaks :: control :: '
			+ 'M-OPEN-TRAIL-EMPTY-UNGUARDED',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testOpenCommentParamsLineCommentBreaks :: control :: '
			+ 'M-OPEN-TRAIL-SEP-UNGUARDED',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testStatementCatchKeepsItsGap :: control :: '
			+ 'M-CLOSE-TRAIL-BLOCK-BREAKS,M-CATCH-CLOSE-TRAIL-ANY',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testStatementElseChainKeepsTheKeywordGlued :: control :: '
			+ 'M-CLOSE-TRAIL-BLOCK-BREAKS',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testValueCatchKeepsTheKeywordGlued :: control :: M-CLOSE-TRAIL-BLOCK-BREAKS',
		'unit.grammar.haxe.HxCloseTrailBlockCommentWriteTest#testValueElseChainKeepsTheKeywordGlued :: control :: '
			+ 'M-CLOSE-TRAIL-BLOCK-BREAKS',
		'unit.grammar.haxe.HxCloseTrailKeywordWriteTest#testDoWhileKeepsItsIndent :: control :: M-PENDING-HARDLINE-BLANK-FLUSHED',
		'unit.grammar.haxe.HxCloseTrailKeywordWriteTest#testStatementCatchKeepsItsIndent :: guard :: ',
		'unit.grammar.haxe.HxCloseTrailKeywordWriteTest#testStatementElseIfChainKeepsItsIndent :: control :: '
			+ 'M-PENDING-HARDLINE-BLANK-FLUSHED',
		'unit.grammar.haxe.HxCloseTrailKeywordWriteTest#testStatementElseKeepsItsIndent :: control :: M-PENDING-HARDLINE-BLANK-FLUSHED',
		'unit.grammar.haxe.HxCloseTrailKeywordWriteTest#testValueCatchKeepsItsIndent :: control :: M-PENDING-HARDLINE-BLANK-FLUSHED',
		'unit.grammar.haxe.HxCloseTrailKeywordWriteTest#testValueElseIfChainKeepsItsIndent :: control :: M-PENDING-HARDLINE-BLANK-FLUSHED',
		'unit.grammar.haxe.HxCloseTrailKeywordWriteTest#testValueElseKeepsItsIndent :: control :: M-PENDING-HARDLINE-BLANK-FLUSHED',
		'unit.grammar.haxe.HxComprehensionAllmanFixedPointTest#testAChainFollowsTheBreak :: control :: M-BREAK-COMMITTED-BARE',
		'unit.grammar.haxe.HxComprehensionAllmanFixedPointTest#testALambdaBodyFollowsTheBreak :: control :: M-BREAK-COMMITTED-BARE',
		'unit.grammar.haxe.HxComprehensionAllmanFixedPointTest#testALiteralHostKeepsItsAllmanDecision :: control :: '
			+ 'M-BREAK-OBJECT-LITERAL-HOST',
		'unit.grammar.haxe.HxComprehensionAllmanFixedPointTest#testAMultiArgumentHostFollowsTheBreak :: control :: '
			+ 'M-BREAK-MULTI-ITEM-HOST-OFF',
		'unit.grammar.haxe.HxComprehensionAllmanFixedPointTest#testAParenMeasuresTheBreakBare :: control :: M-PAREN-MEASURES-COMMITTED',
		'unit.grammar.haxe.HxComprehensionAllmanFixedPointTest#testAStaticallyBrokenLambdaBodyStaysGlued :: control :: '
			+ 'M-BREAK-READBACK-BARE',
		'unit.grammar.haxe.HxComprehensionAllmanFixedPointTest#testOneAlternativePerBreak :: control :: M-BREAK-EVERY-NODE',
		'unit.grammar.haxe.HxComprehensionAllmanGluedSpaceTest#testANestedForKeepsItsSpace :: control :: M-ALLMAN-GLUED-SPACE-UNGUARDED',
		'unit.grammar.haxe.HxComprehensionAllmanGluedSpaceTest#testOneWriteIsAFixedPointAtTheLimit :: control :: M-ALLMAN-GLUED-SPACE-KEPT',
		'unit.grammar.haxe.HxComprehensionCuddledOpenTest#testAFlatItemThatStillOverflowsCuddlesItsHead :: control :: M-CUDDLE-FLATONLY',
		'unit.grammar.haxe.HxComprehensionCuddledOpenTest#testAnItemOverflowingTheGlueColumnCuddlesAndDropsItsBody :: control :: '
			+ 'M-CUDDLE-FALLBACK-INDENT',
		'unit.grammar.haxe.HxComprehensionCuddledOpenTest#testTheGlueOverflowLayoutIsIdempotent :: control :: M-CUDDLE-FALLBACK-INDENT',
		'unit.grammar.haxe.HxComprehensionCuddledOpenTest#testTheReportedLayoutIsIdempotent :: control :: M-CUDDLE-FLATONLY',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testFitLineMovesANonFlatBodyOffTheHeadLine :: control :: '
			+ 'M-FIRST-LINE-FIT',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testFitLinePullsUpABodyThatFits :: control :: M-NO-WIRE',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testKeepReadsTheSourceBreak :: control :: M-ALWAYS-SAME',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testNextLayoutIsIdempotent :: control :: M-ALWAYS-SAME',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testNextPutsTheBodyOnItsOwnLine :: control :: M-NO-WIRE',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testSameKeepsAFlatBodyOnTheHeadLine :: control :: M-ALWAYS-NEXT',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testSamePullsTheBodyUpOntoTheHeadLine :: control :: M-NO-WIRE',
		'unit.grammar.haxe.HxComprehensionForBodyPolicySliceTest#testTheSpecificKeyOutranksTheExpressionIfFanout :: control :: '
			+ 'M-FANOUT-FIRST',
		'unit.grammar.haxe.HxComprehensionIfElseBodySliceTest#testFilterIfWithoutElseStillCuddles :: control :: M-CUDDLE-OFF',
		'unit.grammar.haxe.HxComprehensionIfElseBodySliceTest#testIfElseBodyCuddles :: control :: M-ELSE-GATE',
		'unit.grammar.haxe.HxComprehensionIfElseBodySliceTest#testIfElseBodyCuddlesWithTightBrackets :: control :: M-ELSE-GATE',
		'unit.grammar.haxe.HxComprehensionIfElseBodySliceTest#testIfElseBodyUnderFitLineLeavesTheHeadLine :: control :: M-FIRST-LINE-FIT',
		'unit.grammar.haxe.HxComprehensionIfElseBodySliceTest#testNestedComprehensionsChooseTheSameLayout :: control :: M-ELSE-GATE',
		'unit.grammar.haxe.HxComprehensionIfElseBodySliceTest#testNestedComprehensionsUnderFitLineStaircase :: control :: '
			+ 'M-FIRST-LINE-FIT',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testBlockTailKeepsSemiAfterEnd :: control :: M-TRAILSEP-KEEP-OFF',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testBlockTailStillDropsSemiAfterSwitch :: control :: M-TRAILSEP-KEEP-ALL',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testElseBodyKeepsSemiAfterEnd :: control :: M-TRAILOPT-KEEP-OFF',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testElseIfChainTailKeepsSemiUnderRemove :: control :: M-TRAILOPT-KEEP-OFF',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testLoopBodiesKeepSemiAfterEnd :: control :: M-TRAILOPT-KEEP-OFF',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testRedundantSemiAfterBlockStillDropped :: control :: M-TRAILOPT-KEEP-UNGATED',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testSemiAfterEndStaysBeforeTrailingComment :: control :: M-SEP-GLUE-OFF',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testTerminatedRegionGainsNoSemi :: control :: M-TRAILOPT-KEEP-PRESENCE-BLIND',
		'unit.grammar.haxe.HxCondEndTerminatorSliceTest#testThenBodyKeepsSemiAfterEnd :: control :: M-TRAILOPT-KEEP-OFF',
		'unit.grammar.haxe.HxCondExprBodyBreakFixedPointTest#testACallKeepsTheArgumentGluedInOneWrite :: control :: M-BREAKMARK-UNRECORDED',
		'unit.grammar.haxe.HxCondExprBodyBreakFixedPointTest#testAComprehensionCuddlesInOneWrite :: control :: M-BREAKMARK-SITE-OFF',
		'unit.grammar.haxe.HxCondExprBodyBreakFixedPointTest#testAFitRegionKeepsItsLadder :: control :: M-BREAKMARK-FIT-NAMED',
		'unit.grammar.haxe.HxCondExprBodyBreakFixedPointTest#testANestedListFollowsTheLayoutItCommitted :: control :: '
			+ 'M-BREAKMARK-ONE-ROUND',
		'unit.grammar.haxe.HxCondExprBodyBreakFixedPointTest#testARebuiltMarkKeepsItsToken :: control :: M-BREAKMARK-REBUILD-FRESH-TOKEN',
		'unit.grammar.haxe.HxCondExprBodyBreakFixedPointTest#testOneWriteIsAFixedPointAtEveryWidth :: control :: M-BREAKMARK-UNREAD',
		'unit.grammar.haxe.HxCondExprFitRegionFixedPointTest#testACallArgumentRegionSettlesInOneWrite :: control :: '
			+ 'M-REGION-UNNAMED,M-REGION-SEAMS-SOFT,M-REGION-MARK-ALWAYS',
		'unit.grammar.haxe.HxCondExprFitRegionFixedPointTest#testAChainLinkAfterARegionSettlesInOneWrite :: control :: '
			+ 'M-CHAIN-REGION-OFFER-OFF,M-CHAIN-CLOSE-UNRESOLVED,M-CHAIN-AFTERFIRST-COMMIT-UNREAD,M-CHAIN-ONEPERLINE-COMMIT-UNREAD,'
			+ 'M-TAIL-RESOLVE-IGNORED,M-OFFER-WANTED-DROPS',
		'unit.grammar.haxe.HxCondExprFitRegionFixedPointTest#testAComprehensionBodyRegionUnderAnArrowSettlesInOneWrite :: control :: '
			+ 'M-REGION-OFFER-THROUGH-BODIES,M-NESTED-THROUGH-BODIES',
		'unit.grammar.haxe.HxCondExprFitRegionFixedPointTest#testAnElseifRegionInAComprehensionSettlesInOneWrite :: control :: '
			+ 'M-REGION-SEAMS-BOUNDED',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testALeadingCommentDoesNotHideARegionFromTheTrailingCommaKnob :: control :: '
			+ 'M-TRAIL-REGION-UNDER-COMMENT,M-LEAD-BLOCK-COMMENT-END',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testALineCommentedListAddsNoTrailingCommaAfterARegion :: control :: '
			+ 'M-TRAIL-AFTER-REGION,M-TRAIL-FORCEMULTI-UNGATED,M-TRAIL-CALL-FORCEMULTI-UNGATED',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testAnElidedOuterCommaAfterARegionIsNoLineBreak :: control :: '
			+ 'M-ELIDED-GAP-HARD,M-ELIDED-SEP-KEPT',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testEnumCtorParamsKeepTheirSeparatorsAroundARegion :: control :: '
			+ 'M-ENUM-CTOR-PARAMS-PLAIN',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testParamsKeepTheCommaInsideAnElseifRegion :: control :: M-COND-PARAM-ELSEIF-PLAIN',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testParamsKeepTheCommaInsideTheElseRegion :: control :: '
			+ 'M-COND-PARAM-ELSE-PLAIN,M-ELIDED-SEP-KEPT',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testParamsUnderLeadingBreakFillGainNoComma :: control :: '
			+ 'M-REGION-GLUED,M-ELIDED-SEP-KEPT',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testTheTrailingCommaKnobAddsNoneAfterAClassNotationField :: control :: '
			+ 'M-TRAIL-AFTER-SEMI',
		'unit.grammar.haxe.HxCondListSeparatorWriteTest#testTheTrailingCommaKnobAddsNoneAfterARegionEndingTheList :: control :: '
			+ 'M-TRAIL-AFTER-REGION,M-TRAIL-CASCADE-UNGATED',
		'unit.grammar.haxe.HxCondSpliceOwnLineSliceTest#testOwnLineStatementConditionalAfterMetaBlockStaysStructured :: control :: '
			+ 'M-WORDOP-NO-RESTORE',
		'unit.grammar.haxe.HxCondUnbalancedRegionSliceTest#testBlockTailRegionCollapsesEmptyCatchBody :: control :: '
			+ 'M-COND-BLOCK-TAIL-NEVER',
		'unit.grammar.haxe.HxCondUnbalancedRegionSliceTest#testBlockTailRegionKeepsHeadRawAndBodyStructural :: control :: '
			+ 'M-COND-BLOCK-TAIL-NEVER',
		'unit.grammar.haxe.HxCondUnbalancedRegionSliceTest#testOpenerCloserPairKeepsOpenerACondSpliceStmt :: control :: '
			+ 'M-COND-BLOCK-TAIL-NEVER',
		'unit.grammar.haxe.HxConditionalExprFitSliceTest#testOverwideGluedBreaksAtDirectiveSeams :: control :: M-NEWLINE-SIGNALS-NONE',
		'unit.grammar.haxe.HxDeclCommentSlotWriteTest#testMandatoryLeadKeepsTheComment :: control :: '
			+ 'M-BEFORE-LEAD-MANDATORY-NONE,M-BEFORE-LEAD-WRITER-MANDATORY-NONE',
		'unit.grammar.haxe.HxDeclCommentSlotWriteTest#testOptionalLeadKeepsTheComment :: control :: '
			+ 'M-BEFORE-LEAD-CAPTURE-NONE,M-BEFORE-LEAD-WRITER-OPT-NONE',
		'unit.grammar.haxe.HxDeclCommentSlotWriteTest#testReturnTypeLineCommentBreaksBeforeTheBody :: control :: '
			+ 'M-FNBODY-GAP-COMMENT-NONE',
		'unit.grammar.haxe.HxDeclCommentSlotWriteTest#testReturnTypeToBlockBodyKeepsTheComment :: control :: M-FNBODY-GAP-COMMENT-NONE',
		'unit.grammar.haxe.HxDeclCommentSlotWriteTest#testReturnTypeToExpressionBodyKeepsTheComment :: control :: '
			+ 'M-FNBODY-GAP-COMMENT-NONE',
		'unit.grammar.haxe.HxDoWhileThrowTryCatchSliceTest#testPlainWriterDropsTheSemicolonBeforeWhile :: control :: M-DOWHILE-PLAIN-SEMI',
		'unit.grammar.haxe.HxDroppedSepCommentTest#testABlockCommentStaysOnTheElement :: control :: M-DROPPED-SEP-BLOCK-REHOMED',
		'unit.grammar.haxe.HxDroppedSepCommentTest#testADroppedSeparatorsCommentIsWrittenWhereTheNextParseReadsIt :: control :: '
			+ 'M-DROPPED-SEP-UNREHOMED,M-TAIL-ABSENT-FIELD-STOPS,M-TAIL-ARRAY-SLOT-UNREAD,M-TAIL-CALL-SLOT-UNREAD,'
			+ 'M-TAIL-INFIX-UNREAD,M-TAIL-OPERAND-UNREAD,M-TAIL-PREFIX-UNREAD,M-TAIL-TERNARY-UNREAD',
		'unit.grammar.haxe.HxDroppedSepCommentTest#testAKeptSeparatorKeepsTheCommentAfterIt :: control :: M-DROPPED-SEP-KEPT-REHOMED',
		'unit.grammar.haxe.HxDroppedSepCommentTest#testATailThatCapturesNothingKeepsTheCommentOnTheElement :: control :: '
			+ 'M-TAIL-ONLY-KNOWN-METAS',
		'unit.grammar.haxe.HxDroppedSepCommentTest#testAnOccupiedTailKeepsBothComments :: control :: '
			+ 'M-TAIL-SLOT-OVERWRITTEN,M-TAIL-ALT-SLOT-OVERWRITTEN,M-TAIL-WRITTEN-SEMICOLON-IGNORED',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testBareBodyElseIfTrailsCommentAfterCondition :: control :: '
			+ 'M-EICR-AFTERCOND-RESET',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testBracedElseIfGluesAndTrailsCommentAfterOpenCurly :: control :: '
			+ 'M-EICR-BOUNDARY-SKIP',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testChainReflowsEveryLinkIndependently :: control :: M-EICR-BOUNDARY-SKIP',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testCommentWithOpenDelimitersIsSafe :: control :: M-EICR-BOUNDARY-SKIP',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testConditionWrapPolicySeesTheRelocatedComment :: control :: '
			+ 'M-EICR-BOUNDARY-SKIP',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testDeepRefusedChainStaysCorrect :: control :: M-EICR-HEADTEXT-ANY',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testDefaultOptionsAreByteInert :: control :: M-KEEP-ELSEIF-ALWAYS-GLUED',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testEmptyThenBodyDoesNotMigrateTheComment :: control :: M-EICR-HEADTEXT-ANY',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testExistingHeadTrailingCommentRefusesReflow :: control :: M-EICR-HEADTEXT-ANY',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testInlineBodyPolicyLeavesNoAnchorAndRefuses :: control :: M-EICR-HEADTEXT-ANY',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testKeepElsePolicyDisablesTheReflow :: control :: M-KEEP-ELSEIF-ALWAYS-GLUED',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testKnobOffKeepsEveryPreKnobLayout :: control :: M-EICR-KNOB-IGNORED',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testOverLongGluedHeadLineIsAccepted :: control :: M-EICR-BOUNDARY-SKIP',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testProbeShapedBodyRefusesReflow :: control :: M-EICR-SOFTLINE-ANCHOR',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testReflowedFormsAreIdempotent :: control :: M-EICR-BOUNDARY-SKIP',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testSingleStatementBraceRemovalAndReflowLandInOnePass :: control :: '
			+ 'M-EICR-KNOB-IGNORED',
		'unit.grammar.haxe.HxElseIfCommentReflowSliceTest#testWrappedConditionAnchorsAfterTheOpenCurly :: control :: '
			+ 'M-EICR-BOUNDARY-SKIP,M-EICR-KNOB-IGNORED',
		'unit.grammar.haxe.HxElseIfOptionsTest#testElseIfNextMovesNestedIfToNextLine :: control :: M-KEEP-ELSEIF-NEXT-OFF',
		'unit.grammar.haxe.HxElseIfOptionsTest#testElseIfNextOnlyLastLevelKeepsFirstLevelInline :: control :: M-KEEP-ELSEIF-NEXT-OFF',
		'unit.grammar.haxe.HxExprForGuardGlueSliceTest#testArrowForForBlockGluesTheWholeSpine :: control :: M-STRICT-HEAD-DELIM-OFF',
		'unit.grammar.haxe.HxExprForGuardGlueSliceTest#testArrowForIfBlockGluesTheWholeSpine :: control :: M-STRICT-HEAD-DELIM-OFF',
		'unit.grammar.haxe.HxExprParenBrokenChainTest#testABrokenChainOpensAtItsIndent :: control :: M-PAREN-BROKEN-CHAIN-PINNED',
		'unit.grammar.haxe.HxExprParenBrokenChainTest#testAChainOnlyAnOperandBrokeOpensAsWithoutKeep :: control :: '
			+ 'M-PAREN-KEPT-CHAIN-OPERAND',
		'unit.grammar.haxe.HxExprParenBrokenChainTest#testAKeptBrokenChainAfterAReturnBreakStaysGlued :: control :: '
			+ 'M-PAREN-KEPT-CHAIN-OPENS',
		'unit.grammar.haxe.HxExprParenBrokenChainTest#testAKeptChainInAParenIsOneWriteUnderEveryReturnPolicy :: control :: '
			+ 'M-PAREN-KEPT-CHAIN-SOURCE-NEST',
		'unit.grammar.haxe.HxExprParenBrokenChainTest#testOneWriteIsAFixedPointAcrossTheBoundary :: control :: M-PAREN-BROKEN-CHAIN-PINNED',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testCallArgumentListBreaksInsteadOfTheFirstParen :: control :: '
			+ 'M-PAREN-LIST-BREAK',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testChainProbeKeepsBreakingItsOwnLink :: control :: M-PAREN-CHAIN-PREDICTS',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testCollapseTailParenIsNotABreakPoint :: control :: M-PAREN-SIBLING-COLLAPSE',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testLambdaParenMeasuresItsOwnBreakableContent :: control :: '
			+ 'M-PAREN-EXACT-CONTENT',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testNestedCallBreaksItsOuterArgumentList :: control :: '
			+ 'M-CHAIN-REST-IN-KEPT-PAREN',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testPinnedArgumentListIsMeasuredFlat :: control :: M-PAREN-FLATTEN-REGION',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testSecondParenOpensWhenOnlyItCrossesDiv :: control :: M-PAREN-SIBLING-FLAT',
		'unit.grammar.haxe.HxExprParenDivOpenBoundaryTest#testUnmeasuredRestNodeEndsColumnPredictions :: control :: M-PAREN-EXACT-REST',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testDocOnSecondDeclIsNotAFileHeader :: control :: M-FILEHEADER-ANY-DECL',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testFileHeaderBlankBeforeConditionalImportBlock :: control :: '
			+ 'M-FILEHEADER-COND-OPAQUE',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testFileHeaderBlankBeforeLeadingImport :: control :: M-FILEHEADER-HEAD-NOT-PIU',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testFileHeaderBlankBeforePackage :: control :: M-FILEHEADER-HEAD-NOT-PIU',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testHeaderSeparatedFromDocButDocKeepsItsType :: control :: '
			+ 'M-FILEHEADER-NO-TWO-COMMENT-ARM,M-FILEHEADER-ANY-COMMENT',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testLineCommentHeaderLeavesDocAttached :: control :: '
			+ 'M-FILEHEADER-ANY-COMMENT-KIND,M-FILEHEADER-ANY-COMMENT',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testNoFileHeaderBlankWithoutImports :: control :: M-FILEHEADER-HEAD-ALWAYS-PIU',
		'unit.grammar.haxe.HxFitLineBodyGlueSliceTest#testArrowLambdaBodyGluesAfterTheArrow :: control :: M-PAREN-PIN-NONE',
		'unit.grammar.haxe.HxFitLineBodyGlueSliceTest#testChainOperandParenStillOpens :: control :: M-COLLAPSE-GLUE-REST-CHAIN-SKIPPED',
		'unit.grammar.haxe.HxFitLineBodyGlueSliceTest#testComprehensionFilterBodyGluesToTheIfHead :: control :: M-PAREN-PIN-NONE',
		'unit.grammar.haxe.HxFitLineBodyGlueSliceTest#testGluedBodyIsIdempotent :: control :: M-PAREN-PIN-NONE',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testABareCallStatementOpensItsArgumentListInsteadOfSplittingTheChain :: '
			+ 'control :: M-FN-LAMBDA-BODY-DEFERRED',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testABlockBodiedFunctionLambdaKeepsItsGluedHead :: guard :: ',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testAFittingFunctionLambdaArgumentStaysOnOneLine :: guard :: ',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testAFourHundredColumnFunctionLambdaBodyBreaksEveryPointItOwns :: '
			+ 'control :: M-FN-LAMBDA-BODY-DEFERRED',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testAReturnBodiedFunctionLambdaIsUnchanged :: guard :: ',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testStatementIfWithFunctionLambdaIfBodyBreaksInsteadOfOverflowing :: '
			+ 'control :: M-FN-LAMBDA-BODY-DEFERRED',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testTheArrowSpellingOfTheSameBodyIsUnchanged :: guard :: ',
		'unit.grammar.haxe.HxFunctionLambdaBodyWidthSliceTest#testTheConcatenatedThrowNoLongerContinuesAtTheStatementIndent :: '
			+ 'control :: M-FN-LAMBDA-BODY-DEFERRED',
		'unit.grammar.haxe.HxGlueWidthSliceTest#testBreakIsTakenWhenItJustFixesTheOverflow :: control :: M-GLUE-NEVER-BREAKS',
		'unit.grammar.haxe.HxGlueWidthSliceTest#testCaseBodyGlueInheritsTheSameAnswer :: control :: M-GLUE-NEVER-BREAKS',
		'unit.grammar.haxe.HxGlueWidthSliceTest#testGlueTurnedBreakIsNotASiblingSymmetryTrigger :: control :: M-GLUE-NEVER-BREAKS',
		'unit.grammar.haxe.HxGlueWidthSliceTest#testOverWideGluedHeaderBreaksTheBody :: control :: M-GLUE-NEVER-BREAKS',
		'unit.grammar.haxe.HxGlueWidthSliceTest#testReturnBodyGlueInheritsTheSameAnswer :: control :: M-GLUE-NEVER-BREAKS',
		'unit.grammar.haxe.HxGroupRestProbeStructStarTest#testCasePatternTypeParamsDeclineTheRestProbe :: control :: '
			+ 'M-PATTERN-RESTPROBE-UNSET,M-SEPSTAR-RESTPROBE-UNGATED',
		'unit.grammar.haxe.HxGroupRestProbeStructStarTest#testObjectLiteralPatternDeclinesTheRestProbeInBothWriters :: control :: '
			+ 'M-PATTERN-RESTPROBE-UNSET,M-TRIVIASEP-RESTPROBE-UNGATED,M-SEPSTAR-RESTPROBE-UNGATED',
		'unit.grammar.haxe.HxIfExprCondWrapSliceTest#testArrowBodyIfOverflowChainExplodesCond :: control :: M-ARROW-HEAD-WIDTH-NONE',
		'unit.grammar.haxe.HxIfExprCondWrapSliceTest#testExplodedSourceIsIdempotent :: control :: M-ARROW-HEAD-WIDTH-NONE',
		'unit.grammar.haxe.HxIfStmtExprPositionDispatchTest#testElseBodyDualFlagDispatchesAtExpressionPosition :: control :: '
			+ 'M-ELSE-SEP-EXPR-BLIND',
		'unit.grammar.haxe.HxIndentCaseLabelsOptionsTest#testIndentCaseLabelsFalseFlushesLabelsWithSwitch :: control :: '
			+ 'M-KWREF-TIGHT-LEAD-BLIND',
		'unit.grammar.haxe.HxIndentCaseLabelsOptionsTest#testIndentCaseLabelsTrueKeepsLabelsIndented :: control :: '
			+ 'M-KWREF-TIGHT-LEAD-BLIND',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testBrokenShapeIsIdempotent :: control :: M-LOOPIF-NEVER',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testDoWhileIfElseBreaksUnderHeader :: control :: M-LOOPIF-NOWRAP',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testEveryPlacementObeysTheKey :: control :: M-LOOPIF-POLICY-BLIND',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testForIfElseBreaksUnderHeader :: control :: M-LOOPIF-NEVER',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testGuardIfWithoutElseStaysGlued :: control :: M-LOOPIF-ALWAYS',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testGuardStaysGluedUnderEveryPlacement :: control :: M-LOOPIF-ALWAYS',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testKeepPlacementObeysTheKeyAndStillReadsTheSource :: control :: M-LOOPIF-KEEP-BLIND',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testKnobOffRejoinsAHandBrokenSite :: guard :: ',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testNonLoopAndNonIfBodiesUnchanged :: control :: M-LOOPIF-ALWAYS',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testReportedConfigGuardStaysGlued :: control :: M-LOOPIF-ALWAYS',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testReportedSiteBreaksUnderHeader :: control :: M-LOOPIF-NEVER',
		'unit.grammar.haxe.HxLoopBodyIfElseSliceTest#testWhileIfElseBreaksUnderHeader :: control :: M-LOOPIF-NEVER',
		'unit.grammar.haxe.HxNamedFnExprSliceTest#testNamedFnExprBlockBodyEndsItsStatement :: control :: '
			+ 'M-NAMED-FN-STMT-NO-ARM,M-NAMED-FN-NOT-BRACE-ENDED,M-NAMED-FN-EXPR-BODY-RELAXED',
		'unit.grammar.haxe.HxNestingCostTest#testCollapsePassComputesEachSharedNodeOnce :: control :: '
			+ 'M-COLLAPSE-REWRITE-MEMO-OFF,M-COLLAPSE-SUBTREE-MEMO-OFF,M-COLLAPSE-COMMIT-MEMO-OFF',
		'unit.grammar.haxe.HxNestingCostTest#testEachBodyIsWrittenOnce :: control :: M-FOR-BODY-PROBE-EAGER,M-CHAIN-WALK-EAGER',
		'unit.grammar.haxe.HxNestingCostTest#testParserRunsEachNestedAtomOnce :: control :: '
			+ 'M-PARSE-MEMO-REPLAY-OFF,M-PARSE-MEMO-STASHED-SKIP',
		'unit.grammar.haxe.HxNestingCostTest#testWriterDocKeepsItsSharing :: control :: M-GROUPIFY-SHARED-OFF',
		'unit.grammar.haxe.HxObjectLitForcedNoWrapProbeTest#testOneWriteIsAFixedPointAtEveryWidth :: control :: M-FORCED-NOWRAP-UNPROBED',
		'unit.grammar.haxe.HxObjectLitLineLengthRuleFixedPointTest#testAWidthRuleLiteralInAComprehensionSettlesInOneWrite :: control :: '
			+ 'M-WIDTH-RULE-DECISION-UNREAD,M-WIDTH-RULE-TAIL-UNREAD',
		'unit.grammar.haxe.HxOpAddChainOperatorFirstSliceTest#testGlueBoundaryOneColumnOverBreaks :: control :: '
			+ 'M-COLLAPSE-CHAIN-GROUP-PLAIN-ONLY',
		'unit.grammar.haxe.HxParamLeadingCommentWriteTest#testAGluedBlockCommentStaysOnItsParameterLine :: control :: '
			+ 'M-CASCADE-LEAD-BREAKS,M-CLOSE-LOOP-LEAD-UNGLUED',
		'unit.grammar.haxe.HxParamLeadingCommentWriteTest#testAnOwnLineCommentUnderNoWrapLaysTheParametersOutOnePerLine :: control :: '
			+ 'M-NOWRAP-LEAD-IN-CASCADE',
		'unit.grammar.haxe.HxParenTernaryOpenWrapSliceTest#testFillLineExpressionWrapOpensParenOpAddSub :: control :: '
			+ 'M-COLLAPSE-GLUE-TERNARY',
		'unit.grammar.haxe.HxReservedNameSliceTest#testAKeywordANewerHaxeAddedStillNamesAVersionGatedDeclaration :: control :: '
			+ 'M-RESERVED-VERSIONED-REFUSED',
		'unit.grammar.haxe.HxReservedNameSliceTest#testAReservedWordIsNoFunctionParameterOrBinderName :: control :: '
			+ 'M-RESERVED-IDENT-NAME,M-RESERVED-FN-NAME',
		'unit.grammar.haxe.HxReservedNameSliceTest#testAReservedWordIsNoLocalOrFieldName :: control :: M-RESERVED-VAR-NAME',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testArrayStillBreaksForAShortTrailingCall :: control :: M-RESTPROBE-COLUMN-FLAT',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testCallStillBreaksBeforeAChainLink :: control :: M-RESTPROBE-FULL-LINE',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testHintStaysFlatBeforeALiteralThatBreaksByItself :: control :: '
			+ 'M-RESTPROBE-COLUMN-GUESS,M-REST-FORCEFLAT-FRAME-INEXACT',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testHintStaysFlatBeforeAShortInitializer :: guard :: ',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testHintStaysFlatBeforeArgumentsThatBreakByThemselves :: control :: '
			+ 'M-RESTPROBE-COLUMN-GUESS',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testHintThatDoesNotFitStillBreaks :: guard :: ',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testHintWithTwoNestedAnonsStaysFlat :: control :: '
			+ 'M-REST-GROUP-FRAME-INEXACT,M-REST-GROUP-NODE-INEXACT',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testParameterHintBeforeABodyIsUnchanged :: guard :: ',
		'unit.grammar.haxe.HxRestProbeSelfBreakSliceTest#testTheFlatHintIsAFixedPoint :: control :: M-RESTPROBE-COLUMN-GUESS',
		'unit.grammar.haxe.HxSameLineOptionsTest#testStatementBareTryBreaksByDefault :: control :: M-BLOCK-SHAPE-EQUIV-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testBareThenIfGetsBracesAdded :: control :: M-SSB-WRAP-DIRECTION',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testBareThenOppositeBracedElseGetsBraces :: control :: M-SSB-CHAIN-TAIL-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testBareTryCatchForBodyUnbraced :: control :: M-BLOCK-SHAPE-EQUIV-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testBareTryCatchIfBodyUnbraced :: control :: M-BLOCK-SHAPE-EQUIV-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testBareTryCatchWhileBodyUnbraced :: control :: M-BLOCK-SHAPE-EQUIV-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testBracedCatchBodySealsTryCatchBeforeElse :: control :: '
			+ 'M-SSB-FRAME-OFF,M-SSB-DANGLING-NONE,M-SSB-TAIL-SEALED-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testBracedThenBodySealsNestedGuardLoop :: control :: M-SSB-FRAME-BLANKET',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testChainKeeperForcesBracesOnEveryBareBranch :: control :: M-SSB-CHAIN-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testDanglingElseThroughLoopBodyKeepsBraces :: control :: '
			+ 'M-SSB-FRAME-OFF,M-SSB-DANGLING-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testDeepMixedElseIfChainKeepsAllBraced :: control :: M-SSB-CHAIN-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testDoWhileBodyUnbraced :: control :: M-SSB-DOBODY-KEEP',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testElseBlockSingleIfCollapsesToElseIf :: control :: M-SSB-GATE8-ANY-POSITION',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testElseIfChainLaterBranchForcesEarlierBraces :: control :: M-SSB-CHAIN-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testElseIfChainLinkNotWrapped :: control :: M-SSB-CHAIN-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testForBodyBlockSealsThenBodyAndKeepsItsOwnBraces :: control :: '
			+ 'M-SSB-FRAME-OFF,M-SSB-DANGLING-NONE,M-SSB-TAIL-SEALED-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testIfElseAsymmetryKeepsBothBraced :: control :: M-SSB-CHAIN-TAIL-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testIfElseIfChainKeepsBracesWhenAnyBranchMulti :: control :: M-SSB-CHAIN-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testLoopBodyLoneIfStillUnbraces :: control :: M-SSB-GATE8-ANY-POSITION',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testOpenTrailingCommentTravelsWithTheStatement :: control :: M-SSB-OPEN-TRAIL-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testSealedInnerIfDeBracesUnderTrailingElse :: control :: M-SSB-TAIL-SEALED-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testSuppressFrameDoBodyStillUnwraps :: control :: M-SSB-DOBODY-KEEP',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testSuppressedFrameChainBracesEveryBranch :: control :: M-SSB-CHAIN-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testSwitchSealedInnerIfDeBraces :: control :: M-SSB-TAIL-SEALED-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingCommentElseBodyDeBraces :: control :: M-SSB-ELEM-TRAIL-COMMENT-NONE',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingCommentForBodyDeBraces :: control :: M-SSB-TRAIL-COMMENT-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingCommentIfBodyDeBraces :: control :: M-SSB-TRAIL-COMMENT-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingCommentWhileBodyDeBraces :: control :: M-SSB-TRAIL-COMMENT-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingEmptyStmtAfterForDropsSemiAndDeBraces :: control :: '
			+ 'M-SSB-TRAILOPT-REEMIT',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingEmptyStmtAfterIfDropsSemiAndDeBraces :: control :: '
			+ 'M-SSB-TRAILOPT-REEMIT',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingIfWithOwnElseDeBraces :: control :: M-SSB-ELSE-SPINE-STOP',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testTrailingSemiTerminalElseIfDropsSemiAndDeBraces :: control :: '
			+ 'M-SSB-TRAILOPT-REEMIT',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testValueIfBareElseGainsBraces :: control :: M-SSB-VALUE-WRAP-OFF',
		'unit.grammar.haxe.HxSingleStmtBracesSliceTest#testValueIfBareThenGainsBraces :: control :: M-SSB-VALUE-WRAP-OFF',
		'unit.grammar.haxe.HxSoleArgGluedCloseDedentTest#testSoleArgClosingOnContentKeepsTheGluedClose :: control :: '
			+ 'M-ELSE-SEP-EXPR-BLIND',
		'unit.grammar.haxe.HxStaticLocalStmtSliceTest#testStaticFinalWriterEquals :: control :: M-KWLEAD-NEVER-WORD',
		'unit.grammar.haxe.HxStaticLocalStmtSliceTest#testStaticLocalsRoundTrip :: control :: M-KWLEAD-NEVER-WORD',
		'unit.grammar.haxe.HxStaticLocalStmtSliceTest#testStaticVarWriterEquals :: control :: M-KWLEAD-NEVER-WORD',
		'unit.grammar.haxe.HxTernaryMultilineBranchTest#testABlockBelowTheBranchTopCounts :: control :: M-TERNARY-MLB-NO-DESCENT',
		'unit.grammar.haxe.HxTernaryMultilineBranchTest#testBreakAndAnAbsentKeyBreakTheTernary :: control :: M-TERNARY-MLB-OPTION-IGNORED',
		'unit.grammar.haxe.HxTernaryMultilineBranchTest#testCollectionsAndOpeningGroupsAreNotActedOn :: guard :: ',
		'unit.grammar.haxe.HxTernaryMultilineBranchTest#testInlineBreaksAFirstLinePastTheLimit :: control :: M-TERNARY-MLB-NO-WIDTH-GUARD',
		'unit.grammar.haxe.HxTernaryMultilineBranchTest#testInlineKeepsTheBlockOnTheConditionLine :: control :: M-TERNARY-MLB-INLINE-NONE',
		'unit.grammar.haxe.HxTernaryMultilineBranchTest#testWhatFollowsTheOpeningGroupIsSearched :: control :: '
			+ 'M-TERNARY-MLB-PATH-UNSEARCHED',
		'unit.grammar.haxe.HxTrailingCommentOverflowSliceTest#testCodeAtTheWidthStillCounts :: control :: M-TCO-OVERWIDE-CODE-MOVED',
		'unit.grammar.haxe.HxTrailingCommentOverflowSliceTest#testEverythingOutsideThePositiveListStays :: control :: '
			+ 'M-TCO-DIRECTIVE-MOVED,M-TCO-LEADING-IGNORED,M-TCO-OVERWIDE-CODE-MOVED',
		'unit.grammar.haxe.HxTrailingCommentOverflowSliceTest#testMultiLineCodeKeepsItsComment :: control :: M-TCO-MULTILINE-MOVED',
		'unit.grammar.haxe.HxTrailingCommentOverflowSliceTest#testOverflowingStatementCommentMovesAbove :: control :: M-TCO-KNOB-IGNORED',
		'unit.grammar.haxe.HxTrailingCommentOverflowSliceTest#testTheWidthBoundaryIsInclusive :: control :: M-TCO-BOUNDARY',
		'unit.grammar.haxe.HxTriviaWriteTest#testMultipleOwnLineCommentsBetweenBraceAndElseRoundTrip :: control :: '
			+ 'M-BEFORE-KW-LEADING-DROP',
		'unit.grammar.haxe.HxTriviaWriteTest#testOwnLineCommentBetweenBraceAndElseRoundTrip :: control :: M-BEFORE-KW-LEADING-DROP',
		'unit.grammar.haxe.HxTriviaWriteTest#testSameLineCommentBeforeElseAfterStmtRoundTrip :: control :: M-BEFORE-KW-TRAILING-DROP',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testBareCatchDeBracesWithoutAWrapPass :: control :: '
			+ 'M-SSB-BARE-ILLEGAL,M-SSB-TRY-DEBRACE-NONE,M-SSB-TRY-SUBST-OFF',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testBracedGroupDeBraces :: control :: M-SSB-TRY-DEBRACE-NONE,M-SSB-TRY-SUBST-OFF',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testDanglingElseKeepsBraces :: control :: M-SSB-FRAME-OFF,M-SSB-DANGLING-NONE',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testDeBracedGroupIsIdempotent :: control :: M-KWREF-BARE-BODY-BREAKS-BLIND',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testMultiStatementCatchBracesTheBareTry :: control :: M-SSB-TRY-SUBST-OFF',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testOnlyTheLastCatchKeepsItsTerminator :: control :: '
			+ 'M-TRY-CATCHES-SYM-OFF,M-SSB-TRY-SUBST-OFF,M-SSB-TRY-DEBRACE-NONE',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testOverflowBreaksAtTheSeamNotInsideTheCall :: control :: '
			+ 'M-SSB-TRY-DEBRACE-NONE,M-SSB-TRY-SUBST-OFF',
		'unit.grammar.haxe.HxTryBraceSymmetrySliceTest#testValueTryBracesTheBareBody :: control :: M-TRY-BODY-SYM-OFF,M-SSB-TRY-SUBST-OFF',
		'unit.grammar.haxe.HxValueIfBracketElseBreakSliceTest#testAFittingBracketLadderCollapses :: control :: M-VIF-SEAM-BRACKET-REFUSED',
		'unit.grammar.haxe.HxValueIfBracketElseBreakSliceTest#testAFittingBracketPairStaysFlat :: guard :: ',
		'unit.grammar.haxe.HxValueIfBracketElseBreakSliceTest#testAFlatBracketChainBreaksBeforeEveryElse :: control :: '
			+ 'M-NONCURLY-SAME-DROP',
		'unit.grammar.haxe.HxValueIfBracketElseBreakSliceTest#testAWideBracketPairBreaksIntoTheLadder :: guard :: ',
		'unit.grammar.haxe.HxValueIfBracketElseBreakSliceTest#testOverTheBranchCapTheFitKnobKeepsTheLadder :: control :: '
			+ 'M-NONCURLY-SAME-DROP',
		'unit.grammar.haxe.HxValueIfBracketElseBreakSliceTest#testTheLadderIsAFixedPoint :: guard :: ',
		'unit.grammar.haxe.HxValueIfBracketElseBreakSliceTest#testUnderTheHugTheGluedCloseKeepsItsElse :: control :: '
			+ 'M-VIF-SEAM-GLUE-BLIND',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testAnArrayLiteralBranchHugsTheHead :: control :: M-BRACKET-GLUE-NONE',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testTheKeepTargetLayoutIsIdempotent :: guard :: ',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testTheReportedComprehensionReachesTheTargetLayout :: control :: '
			+ 'M-BRACKET-GLUE-NONE',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testTheSemicolonClosedSourceReachesTheTargetLayout :: control :: '
			+ 'M-BRACKET-GLUE-NONE',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testTheSplitCloserCuddlesTheElseWithNoSemicolonToDrop :: control :: '
			+ 'M-BRACKET-GLUE-NONE',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testTheTargetLayoutIsIdempotent :: control :: M-BRACKET-GLUE-NONE',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testUnderKeepTheKnobHugsTheHeadAndCuddlesTheElse :: control :: '
			+ 'M-BRACKET-GLUE-KEEP-BLIND',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testUnderKeepTheReportedComprehensionReachesTheTargetLayout :: control :: '
			+ 'M-BRACKET-GLUE-KEEP-BLIND',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testUnderKeepWithoutTheKeyTheSourceShapeSurvivesWhole :: guard :: ',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testUnderSameTheBrokenSourceAlreadyReachedTheTargetLayout :: guard :: ',
		'unit.grammar.haxe.HxValueIfBracketHugSliceTest#testWithoutTheKeyTheSemicolonAndTheBreakBothSurvive :: control :: '
			+ 'M-NONCURLY-SAME-DROP',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testABracketBranchKeepsTheSourceBreak :: control :: '
			+ 'M-EXPR-ELSE-PLAIN-SAME,M-NONCURLY-SAME-DROP',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testAnElseLessValueIfKeepsItsTerminator :: control :: M-SBE-UNGATED',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testAnObjectLiteralBranchKeepsItsOwnLine :: control :: M-ELSE-BODY-SAME',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testKeepStillPreservesTheSourceBreak :: control :: M-KEEP-JOINS',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testTheJoinedLayoutIsIdempotent :: control :: M-CURLY-CTORS-NONE',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testTheReportedValueIfJoinsItsElseToTheCurlyClose :: control :: '
			+ 'M-EXPR-ELSE-KEEP',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testTheSemicolonBeforeElseGoesWithTheJoin :: control :: '
			+ 'M-EXPR-ELSE-KEEP,M-EXPR-ELSE-PLAIN-SAME',
		'unit.grammar.haxe.HxValueIfCurlyElseJoinSliceTest#testTheStatementTwinKeepsTheLayoutItAlwaysHad :: guard :: ',
		'unit.grammar.haxe.HxValueIfElseTrailCommentWriteTest#testAGapOpeningWithABreakIsUnchanged :: control :: M-KWTRAIL-GUARD-HARD',
		'unit.grammar.haxe.HxValueIfElseTrailCommentWriteTest#testUnderSameTheCommentKeepsItsLine :: control :: M-KWTRAIL-FLAT-GAP-KEPT',
		'unit.lowering.BeforeLeadingCommentSlotTest#testAMemberWithNoGapCommentIsUnchanged :: guard :: ',
		'unit.lowering.BeforeLeadingCommentSlotTest#testAMultilineGapCommentReachesTheOutput :: control :: M-BEFORE-LEADING-COMMENT-DROP',
		'unit.lowering.BeforeLeadingCommentSlotTest#testAOneLineGapCommentIsCarriedUpstream :: guard :: ',
		'unit.lowering.BranchOutliningTest#testABreakLeavingTheTrialKeepsItInline :: control :: M-OUTLINE-BREAK-BLIND',
		'unit.lowering.BranchOutliningTest#testABreakOfALoopInsideTheTrialMoves :: guard :: ',
		'unit.lowering.BranchOutliningTest#testAForOverAPatternKeepsTheTrialInline :: control :: M-OUTLINE-FOR-PATTERN-BLIND',
		'unit.lowering.BranchOutliningTest#testANestedTrialMovesFirstAndTheOuterOneFollows :: control :: M-OUTLINE-NESTED-ALT-BLIND',
		'unit.lowering.BranchOutliningTest#testAReturnOfAConstantKeepsTheTrialInline :: control :: M-OUTLINE-CONSTANT-AS-CTOR',
		'unit.lowering.BranchOutliningTest#testAReturnThatMayBeNullKeepsTheTrialInline :: control :: M-OUTLINE-NULLABLE-RETURN-BLIND',
		'unit.lowering.BranchOutliningTest#testASwitchKeepsTheTrialInline :: control :: M-OUTLINE-SWITCH-BLIND',
		'unit.lowering.BranchOutliningTest#testATrialReadingARuleLocalMovesIntoAHelper :: control :: M-OUTLINE-OFF',
		'unit.lowering.BranchOutliningTest#testATrialsOwnLocalIsNotCaptured :: guard :: ',
		'unit.lowering.BranchOutliningTest#testATryThatIsNotATrialIsLeftAlone :: guard :: ',
		'unit.lowering.BranchOutliningTest#testAWriteToARuleLocalKeepsTheTrialInline :: control :: M-OUTLINE-WRITE-BLIND',
		'unit.lowering.BranchOutliningTest#testAnUntypedRuleLocalKeepsTheTrialInline :: control :: M-OUTLINE-UNTYPED-CAPTURE',
		'unit.lowering.BranchOutliningTest#testDisagreeingDeclarationsKeepTheTrialInline :: guard :: ',
		'unit.lowering.StarBlockEndedWsRewindSitesTest#testAConditionalBodyKeepsTheStatementAfterASwallowedTerminator :: control :: '
			+ 'M-PEB-WS-REWIND-TRYPARSE-OFF',
		'unit.lowering.StarBlockEndedWsRewindSitesTest#testAConditionalBodyWithAnOrdinaryTerminatorNeedsNoRewind :: guard :: ',
		'unit.lowering.StarBlockEndedWsRewindSitesTest#testANestedBlockKeepsTheStatementAfterASwallowedTerminator :: control :: '
			+ 'M-PEB-WS-REWIND-SEPSTARTS-OFF',
		'unit.lowering.StarBlockEndedWsRewindSitesTest#testANestedBlockWithAnOrdinaryTerminatorNeedsNoRewind :: guard :: ',
		'unit.lowering.StarBlockEndedWsRewindTest#testASwallowedTerminatorBehindTrailingWhitespaceStillEndsTheStatement :: control :: '
			+ 'M-PEB-WS-REWIND-OFF',
		'unit.lowering.StarBlockEndedWsRewindTest#testAnOrdinaryTerminatorNeedsNoRewind :: guard :: ',
		'unit.lowering.StarBlockEndedWsRewindTest#testTheShapeThePredicateAnswersForNeedsNoRewind :: guard :: '
	];

}
