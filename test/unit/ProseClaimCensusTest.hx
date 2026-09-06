package unit;

import testkit.ProseClaims;
import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

/**
 * The prose census: which fixtures claim a role in words that no annotation
 * records, and the ratchet that keeps that list from growing in silence.
 *
 * S96 left this as its stated residue — 39 pins against 14 039 fixtures, with
 * the doc-comment conventions the metadata was meant to replace still unchecked
 * prose everywhere else. `testkit.ProseClaims` is the predicate; `BASELINE`
 * below is what it found at `7331535c`, and `TestRegistry.claims()` is what it
 * finds now. A slice that writes one more such sentence has to add its line
 * here, which is one command:
 *
 * ```
 * haxe test-js.hxml && node bin/test.js --list-claims
 * ```
 *
 * (already sorted by the macro; a STALE `bin/test.js` makes that print the
 * previous tree's answer, which is how S70 lost an afternoon.)
 *
 * The predicate fixtures below ask their questions of hand-written sentences,
 * never of the tree — a fixture reading back the census the macro just computed
 * is derived from the declaration it is meant to check and could not fail (S66).
 * `BASELINE` is the one exception and it is not a discrimination: it is a
 * snapshot, and it is named as one.
 */
@:nullSafety(Strict)
final class ProseClaimCensusTest extends Test {

	/** A sentence in the shape a slice writes when it names the arm that breaks a fixture. */
	private static final ARM_SENTENCE: String = 'Killed by arm M3 (head-is-p/i/u forced false).';

	/** The same sentence, wrapped across a doc-comment line break the way the writer emits one. */
	private static final WRAPPED_ARM_SENTENCE: String = '\n\t * Killed\n\t * by arm M3 (head-is-p/i/u forced false).\n\t ';

	/** The one shape that DENIES an arm relationship instead of claiming one. */
	private static final NEGATED_ARM_SENTENCE: String = 'NOT killed by any arm in this slice, and that is what it is here to say.';

	/** A fixture calling itself the control for a sibling. */
	private static final CONTROL_SENTENCE: String = 'The control for the escape gate: the same two-branch shape still joins.';

	/** `control` about CODE — a rule\'s doc, not a fixture\'s role. */
	private static final CODE_SENTENCE: String = 'A control-flow statement whose TAIL is a region has no recoverable terminator.';

	/** Ordinary prose that claims nothing at all — most of the 14 039. */
	private static final PLAIN_SENTENCE: String = 'The fix walks the member list once and stops at the first modifier.';

	/**
	 * The census as it stood at `a45a05d9` plus this slice, one line per
	 * fixture whose prose claims something no `@:pin` / `@:killer` records.
	 * It was 283 lines carrying 39 `arm` claims; the 30 outside
	 * `unit.grammar.haxe` now name a declared arm, and the 9 that remain are
	 * all in that package.
	 *
	 * Two of the four kinds have an exit: an `arm` line leaves by gaining a
	 * `@:killer`, a `control` line by gaining `@:pin(\'control\')`. `base` and
	 * `vacuity` have none — no annotation can answer "was this red at the base
	 * commit" at build time — so those lines are a register of what is still
	 * prose, not a queue.
	 */
	private static final BASELINE: Array<String> = [
		'unit.check.CoreApiConformanceGateTest#testPreferInlineIsUnaffectedByTheGate :: control',
		'unit.check.DocCommentContinuationCheckTest#testBlankInteriorLineIgnored :: base',
		'unit.check.DocCommentContinuationCheckTest#testCommentShapeInsideStringIgnored :: base',
		'unit.check.DocCommentContinuationCheckTest#testIndentedCodeInsideDocKept :: base',
		'unit.check.DocCommentContinuationCheckTest#testMarkdownBulletNotFlagged :: base',
		'unit.check.ExplicitLocalTypeOracleAbstainTest#testCliFixAbstainsInsteadOfMisAnnotating :: control',
		'unit.check.ExplicitLocalTypeOracleAbstainTest#testCliFixDeclinesAFileTheOracleDoesNotCompile :: control',
		'unit.check.FieldInitAtDeclarationCheckTest#testForeignStaticRefMoved :: control',
		'unit.check.FieldInitAtDeclarationCheckTest#testInClassStaticRefNotMoved :: control',
		'unit.check.FieldInitAtDeclarationCheckTest#testNoSuperCallStillMoved :: control',
		'unit.check.FieldInitAtDeclarationCheckTest#testUnconditionalPrefixStillMoved :: control',
		'unit.check.FieldMutabilityMacroGateTest#testATrivialGetterOfAMacroBuiltTypeIsNotCollapsed :: control',
		'unit.check.FixVerifierProbeRefusalE2ETest#testARefusalStillNamesTheWriterWhenNothingLands :: control',
		'unit.check.FixVerifierProbeRefusalE2ETest#testTheFixtureReallyReachesTheRefusingArm :: vacuity',
		'unit.check.FoldStringLiteralsWidthCheckTest#testBareHeadDoesNotSteerIntoAnUnpricedMerge :: control',
		'unit.check.FoldStringLiteralsWidthCheckTest#testIrreducibleOverwideSegmentNoResegmentOfFittingLines :: vacuity',
		'unit.check.GuardReturnCheckTest#testConstrainedGenericWithoutValueReturnFlagged :: control',
		'unit.check.GuardReturnCheckTest#testNonParamNameFlagged :: control',
		'unit.check.ImportBlockOrderCheckTest#testForeignPackageImportDoesNotSplitTheBlock :: control,base',
		'unit.check.ImportBlockOrderCheckTest#testTheLeadingCommentRefusalNamesTheComment :: base',
		'unit.check.JoinOverrideChainCheckTest#testWrapControlFlagged :: control,vacuity',
		'unit.check.JoinReturnCheckTest#testBranchDeclReadAfterRegionNotFlagged :: control',
		'unit.check.JoinReturnCheckTest#testSiblingBranchDeclsWithoutEscapeStillFlagged :: control',
		'unit.check.LintFixDeclineWiringSliceTest#testAGroupDeferredByARefusedOverlapIsStillOffered :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testAPartialDeclineIsCountedThoughTheRuleAlsoFixed :: control,base',
		'unit.check.LintFixDeclineWiringSliceTest#testARefusedRuleCostsOnlyItsOwnEdits :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testARuleThatSaidNothingIsNotCountedAsDeclining :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testASourceLevelRefusalIsNotBisected :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testAnAcceptedFileIsWrittenAndBlamesNobody :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testGuardRefusalBecomesTheRulesDeclineRow :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testLaterPassGateRefusalStillReachesTheReport :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testLaterPassRefusalIsStillReported :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testSkipTailIsUnchangedWhenNothingWasPartlyFixed :: control',
		'unit.check.LintFixDeclineWiringSliceTest#testSkipTailNamesThePartlyFixedFiles :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testTheDeclineLabelNeverReadsOutOfZero :: base',
		'unit.check.LintFixDeclineWiringSliceTest#testTheRiskyDisclaimerIsOnlyForAPhaseThatDidNotRun :: base',
		'unit.check.LintReportChannelSliceTest#testAScopeArgumentThatMatchedNothingIsNamed :: base',
		'unit.check.LintReportChannelSliceTest#testASpecIsQuotedSoItsBoundariesAreVisible :: base',
		'unit.check.LintReportChannelSliceTest#testMachineFormatsAreNotSubjectToTheInfoCap :: base',
		'unit.check.LintReportChannelSliceTest#testTheJsonAConsumerReceivesAgreesWithTheExitCode :: base',
		'unit.check.LintScopeGateTest#testASameFileRuleStaysOnTheActiveSubset :: control',
		'unit.check.LintScopeGateTest#testTheSameFragmentOutsideAnyScopeIsInvisible :: control',
		'unit.check.LintScopeGateTest#testTheSameLiteralOutsideAnyScopeIsInvisible :: control',
		'unit.check.LintSliceTest#testCommentMentionIsNotAReference :: control',
		'unit.check.LintSliceTest#testGuardedAliasBranchesBindingDifferentModulesNotDuplicate :: control',
		'unit.check.LintSliceTest#testGuardedUsingOnInSetModuleKeptByExtensionCall :: control',
		'unit.check.LintUnusedImportDottedSliceTest#testAliasFindingNamesTheModuleItBinds :: control',
		'unit.check.LintUnusedImportResolutionScopeTest#testLibraryImportUnusedIsInfoWithoutScope :: control',
		'unit.check.LoopGuardCheckTest#testLoopInBracedThenBranchStillFlagged :: control',
		'unit.check.MemberOrderCheckTest#testAConstantReadingThePrivateOneAboveItIsNotReported :: control,base',
		'unit.check.MemberOrderCheckTest#testARelocationUnderTheBudgetStillApplies :: control',
		'unit.check.MemberOrderCheckTest#testASiblingReadPinNamesTheDependency :: base',
		'unit.check.MemberOrderCheckTest#testSkippingThePinnedPairStillReportsTheContainersOtherMisorder :: base',
		'unit.check.MemberOrderCheckTest#testTheOverBudgetDeclineNamesTheBudget :: base',
		'unit.check.MissingVisibilityCheckTest#testFinalWithoutVisibilityStillFlagged :: control',
		'unit.check.MissingVisibilityCheckTest#testFixAppliesForcedViolationInPlainClass :: control',
		'unit.check.MissingVisibilityCheckTest#testFixRefusesForcedExternViolation :: vacuity',
		'unit.check.MissingVisibilityCheckTest#testVisibilityAfterFinalNotFlagged :: base',
		'unit.check.NamingCheckCrossFileFixTest#testAPhantomAllowInACommentDoesNotRefuseACrossFileRename :: control',
		'unit.check.NamingCheckCrossFileFixTest#testCrossFileFixRenamesUnambiguousSubtypeControl :: control',
		'unit.check.NamingCheckCrossFileFixTest#testCrossFileFixThroughTypedefAliasedReceiver :: vacuity',
		'unit.check.NamingCheckCrossFileFixTest#testUnrelatedTypesMayBothClaimTheSameTargetNameInOnePass :: control',
		'unit.check.NamingCheckTest#testExternDeclarationsAreOutsideTheBuiltInConvention :: control',
		'unit.check.OracleCacheTest#testFixNeverConsultsTheCache :: vacuity',
		'unit.check.OracleFixImportLeakTest#testAnAdmissibleLocalStillGetsItsImport :: control',
		'unit.check.OrphanAccessorCheckTest#testTheUnresolvedSupertypeArmAlsoSaysWhyNoEditFollows :: base',
		'unit.check.OrphanAccessorCheckTest#testUnreadableFileNotSpellingThePropertyKeepsTheWarning :: base',
		'unit.check.OrphanAccessorCheckTest#testUnreadableFileSpellingOnlyTheAccessorKeepsTheWarning :: base',
		'unit.check.OrphanAccessorCheckTest#testUnreadableFileSpellingThePropertyKeepsTheDeclaredArmsWarning :: base',
		'unit.check.OrphanAccessorCheckTest#testUnreadablePlainAccessorDeclarationDoesNotBlockTheDeletion :: control',
		'unit.check.OrphanAccessorCheckTest#testUnreadableSubtypeDeclaringThePropertyDowngradesTheReport :: base',
		'unit.check.OversizedTypeCheckTest#testAMajorityDictatedTypeIsNotADecompositionCandidate :: control,base',
		'unit.check.OversizedTypeCheckTest#testAMinorityDictatedTypeIsStillReported :: base',
		'unit.check.OversizedTypeCheckTest#testATypeFatInItsOwnMembersIsStillReported :: base',
		'unit.check.OversizedTypeCheckTest#testAnUnresolvableInterfaceCarvesNothing :: base',
		'unit.check.PreferCaseGuardCheckTest#testAllDottedPatternsFlagged :: control',
		'unit.check.PreferCaseGuardCheckTest#testAllLiteralPatternsFlagged :: control',
		'unit.check.PreferCaseGuardCheckTest#testTypedefAliasToClassFlagged :: control',
		'unit.check.PreferFinalFieldCheckTest#testNonInterfaceFieldStillConverts :: control',
		'unit.check.PreferFinalPublicFieldCheckTest#testCtorConditionalDefaultPlainStringFlagged :: control',
		'unit.check.PreferFinalPublicFieldCheckTest#testNonInterfacePublicFieldStillConverts :: control',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testBlockCommentInARungConditionIsClaimedAndKept :: control',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testFlatTwoBranchStillNotFlagged :: base',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testTerminalTernaryTailSuppliesTheThirdRung :: base',
		'unit.check.PreferIfExpressionChainCheckTest#testBooleanReducibleChainHeadIsNotFlagged :: base',
		'unit.check.PreferIfExpressionChainCheckTest#testBooleanReducibleUnfoldedRungStillConverts :: base',
		'unit.check.PreferIfExpressionChainCheckTest#testChainWithNoBooleanLeafStillFlagged :: base',
		'unit.check.PreferIfExpressionReturnCheckTest#testBoolLiteralRungNotClaimed :: control',
		'unit.check.PreferIfExpressionReturnCheckTest#testMarchRefusedRungValuesNotClaimed :: control',
		'unit.check.PreferIfExpressionReturnCheckTest#testNonReturnStatementDoesNotHideTheCascade :: control',
		'unit.check.PreferInlineCheckTest#testStaticFrameworkNameIsNotCarvedOut :: control',
		'unit.check.PreferStaticExtensionCheckTest#testHedgedVerdictsCarryTheirOwnDeclineReason :: base',
		'unit.check.PreferTernaryAssignmentCheckTest#testTernaryTailedElseIsNotFlagged :: base',
		'unit.check.PreferTernaryReturnCheckTest#testNonReturnRungDoesNotBreakTheDeferral :: control',
		'unit.check.PreferTernaryReturnCheckTest#testTailOfClaimedCascadeDeferred :: control',
		'unit.check.RedundantElseCheckTest#testElseIfChainOfValuedReturnsIsDeferred :: control',
		'unit.check.RedundantMapExistsCheckTest#testUnprovenSiteCarriesItsDeclineReason :: base',
		'unit.check.RedundantParensCheckTest#testInterpolationUncloseableBlockIsStillFlagged :: vacuity',
		'unit.check.RedundantParensOperandArmsTest#testBoundedGreedyContentStillFires :: control',
		'unit.check.RedundantParensOperandArmsTest#testTreeEquivalenceOracleRejectsReassociation :: vacuity',
		'unit.check.RedundantParensTierArmsTest#testAPostfixTokenClosesAGreedyTail :: control',
		'unit.check.RedundantParensTierArmsTest#testAnInteriorUnaryMinusStillFires :: control',
		'unit.check.RedundantThisCheckTest#testInheritedCrossPackageViaImportFlagged :: control',
		'unit.check.RedundantThisCheckTest#testInheritedTransitiveFlagged :: control',
		'unit.check.RedundantToStringCheckTest#testBlockedSiteCarriesItsBlockerAsTheDeclineReason :: base',
		'unit.check.ShadowingLocalCheckTest#testParameterSpellingsAreTheSiblingRulesFindings :: control',
		'unit.check.ShortenTypeRefCheckTest#testASingleSurvivingOccurrenceEarnsNoImport :: control',
		'unit.check.ShortenTypeRefCheckTest#testASuppressedRuntimeUseDoesNotBuyAMacroBodyImport :: control',
		'unit.check.ShortenTypeRefCheckTest#testNestedGuardedImportOfTheSameNameRefusesTheShortForm :: control',
		'unit.check.SimplifyBooleanTernaryCheckTest#testClaimedSpansHoldNothingForARealValuedTernary :: control',
		'unit.check.TrivialGetterShapeCollapseTest#testAliasImportedSupertypeLeavesNoDanglingBackingRead :: control',
		'unit.check.TrivialGetterShapeCollapseTest#testAliasImportedSupertypeRewritesBothFiles :: control',
		'unit.check.UnusedParameterCheckTest#testInlineHelperOwnParameterNotYetReached :: control',
		'unit.check.UnusedPrivateCheckTest#testEmptyCtorKeptWhenSubtypeExtendsATypedefOfIt :: control',
		'unit.check.UnusedPrivateCheckTest#testPrivateMemberKeptWhenSubtypeExtendsImportAlias :: control',
		'unit.cli.AddressCliTest#testRemoveElementStillRemovesAMetaBySelector :: control',
		'unit.cli.ResolutionScopeCliTest#testConfigLessProjectStaysConservativeOnUnresolvableType :: control',
		'unit.cli.ResolutionScopeCliTest#testSymlinkedSpellingOfTheSameTreeStillDedups :: base',
		'unit.core.BodyGroupPrefixChargeConsumerTest#testRestStackAlsoDefersAnInlineNestedBody :: control',
		'unit.format.BraceSymmetrySliceTest#testTheSameBlockOutsideAMacroIsStillDeBraced :: control',
		'unit.format.WrapFlatSourceFixedPointTest#testMultiArgFillPacksACommittedBodyOnPassTwo :: control,base',
		'unit.format.WrapProbeRestAwarenessSliceTest#testArrowRestAwareProbeKeepsItsCtor :: control,base',
		'unit.format.WrapProbeRestAwarenessSliceTest#testPlainProbeKeepsItsCtor :: control,base',
		'unit.grammar.haxe.HxArrowBlockBodyOpenSliceTest#testBoundaryFitsChainBreaksArrowStillCuddled :: control',
		'unit.grammar.haxe.HxArrowBlockBodyOpenSliceTest#testChainNarrowTrailingLinkStaysCuddled :: control',
		'unit.grammar.haxe.HxArrowBlockBodyOpenSliceTest#testNonChainBlockBodiedArrowsUnchanged :: control',
		'unit.grammar.haxe.HxArrowBlockBodyOpenSliceTest#testSelfBreakingObjectLiteralArrowBodyStaysCuddled :: control',
		'unit.grammar.haxe.HxArrowBlockBodyOpenSliceTest#testSoleArrowArgStillBreaksWithCloseOnOwnLine :: control',
		'unit.grammar.haxe.HxComplexItemWrapTest#testComplexItemCountReachesTheContinuationIndent :: vacuity',
		'unit.grammar.haxe.HxComprehensionBracketPolicyTest#testBareMapEntryPadsUnderMapBracketConfig :: control,base',
		'unit.grammar.haxe.HxComprehensionBracketPolicyTest#testPlainArrayStaysArrayLiteralUnderMapBracketConfig :: control',
		'unit.grammar.haxe.HxComprehensionBracketPolicyTest#testReifiedForHeadIsComprehension :: control',
		'unit.grammar.haxe.HxComprehensionBracketPolicyTest#testWrappedComprehensionStaysArrayLiteral :: base',
		'unit.grammar.haxe.HxComprehensionCloserSliceTest#testBlockBodyWithoutCommentKeepsBlockHug :: control',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testDocOnConditionalWrappedTypeStaysAttached :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testDocOnSecondDeclIsNotAFileHeader :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testDocStaysAttachedWhenImportFollowsType :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testDocStaysAttachedWhenUsingFollowsType :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testFileHeaderBlankBeforeConditionalImportBlock :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testFileHeaderBlankBeforeLeadingImport :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testFileHeaderBlankBeforePackage :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testHeaderSeparatedFromDocButDocKeepsItsType :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testLineCommentHeaderLeavesDocAttached :: base',
		'unit.grammar.haxe.HxFileHeaderCommentSliceTest#testNoFileHeaderBlankWithoutImports :: base',
		'unit.grammar.haxe.HxGroupRestProbeStructStarTest#testTypeParamsExactlyOnTheLimitStayFlat :: control',
		'unit.grammar.haxe.HxMaxAnywhereInFileSliceTest#testAGutterlessBlockCommentBlankRunIsNotACapCandidate :: control',
		'unit.grammar.haxe.HxMeasuredMultilineDeclBlankSliceTest#testAConditionalRegionDoesNotHandItsNeighbourABlank :: control,base',
		'unit.grammar.haxe.HxMeasuredMultilineDeclBlankSliceTest#testSourceMultilineThatCollapsesGetsNoBlank :: control,base',
		'unit.grammar.haxe.HxMeasuredMultilineDeclBlankSliceTest#testTwoSingleLineTypesStayTogether :: control,base',
		'unit.grammar.haxe.HxMeasuredMultilineDeclBlankSliceTest#testUnbreakableOverWideHeaderIsStillOneLine :: control,base',
		'unit.grammar.haxe.HxMethodChainAllOrNothingSliceTest#testFittingChainStaysOnOneLine :: control',
		'unit.grammar.haxe.HxMethodChainAllOrNothingSliceTest#testLambdaCloserCuddleSurvivesTheAllOrNothingBreak :: control',
		'unit.grammar.haxe.HxOpAddChainOperatorFirstSliceTest#testGlueBoundaryAtExactlyTheLimitStillGlues :: control',
		'unit.grammar.haxe.HxOpAddChainOperatorFirstSliceTest#testMidChainOpeningParenKeepsTheGlueWhenTheHeadFits :: control',
		'unit.grammar.haxe.HxOpenDelimStashBarrierTest#testKeepModeHonoursOnlyInBracketNewlines :: base',
		'unit.grammar.haxe.HxOptionalSemicolonSliceTest#testPlainWriterStillElidesAfterASingleBraceTerminatedInit :: control',
		'unit.grammar.haxe.HxTernaryCuddleProbeShapeTest#testAfterLastLocationBuildsNoCuddleProbes :: control',
		'unit.query.AddElementSliceTest#testInsertAfterMemberStillLandsBeforeTheNextDoc :: control',
		'unit.query.AddressTest#testTreeAddresserBuildsOneIndexForAWholeTree :: base',
		'unit.query.ApqRefsTest#testARedeclarationInANestedBlockDoesNotEscapeIt :: control',
		'unit.query.ApqRefsTest#testAnonymousFunctionLiteralParameterDoesNotLeakIntoTheEnclosingScope :: control',
		'unit.query.ApqSourceSelectTest#testAstDocReachesPastAConditionalDeclKeywordPrefix :: base',
		'unit.query.ApqSourceSelectTest#testAstSourceOnAModifierPrintsTheDeclarationItPrecedes :: base',
		'unit.query.ApqSourceSelectTest#testAstSourceOnTheAnnotationItselfPrintsOnlyIt :: control,base',
		'unit.query.ApqSourceSelectTest#testAstSourceStopsBelowTheDocBlock :: control,base',
		'unit.query.ApqSourceSelectTest#testSelectOnTheAnnotationItselfStillSpansOnlyIt :: control,base',
		'unit.query.ApqSourceSelectTest#testSelectStopsBelowTheDocBlock :: control,base',
		'unit.query.BodySlotGuardSliceTest#testAllowsBracedIfBodyStatement :: control',
		'unit.query.BodySlotGuardSliceTest#testAllowsPlainBlockStatement :: control',
		'unit.query.BodySlotGuardSliceTest#testAllowsSoleCaseArmStatement :: control',
		'unit.query.BodySlotGuardSliceTest#testAllowsWholeBracelessIfRemoval :: control',
		'unit.query.BodySlotGuardSliceTest#testStatementBodyRefusalAdvisesBraces :: control,base',
		'unit.query.CachingGrammarPluginTest#testProjectionsUnchangedByTheSharedRoot :: vacuity',
		'unit.query.CliAtomicWriteSliceTest#testAChangeSetIsWrittenWholeOrNotAtAll :: base',
		'unit.query.CliAtomicWriteSliceTest#testAReadOnlyFileIsStillRefused :: base',
		'unit.query.CliAtomicWriteSliceTest#testAStagingFailureLeavesTheTargetUntouched :: base',
		'unit.query.CliAtomicWriteSliceTest#testASymlinkedTargetStaysASymlink :: control,base',
		'unit.query.CliAtomicWriteSliceTest#testAnUnwritableFileNoLongerTakesTheRunDown :: base',
		'unit.query.CliAtomicWriteSliceTest#testTheFilesModeSurvivesTheRewrite :: control,base',
		'unit.query.CommentOwnerGuardSliceTest#testACommentThatKeepsItsPlaceUnderACarryIsAccepted :: control',
		'unit.query.CommentOwnerGuardSliceTest#testDeletingTheLastCommentedStatementIsAccepted :: control',
		'unit.query.CommentOwnerGuardSliceTest#testEditOutsideTheGapIsAccepted :: control',
		'unit.query.CommentOwnerGuardSliceTest#testInPlaceRewriteUnderOneCommentIsAccepted :: control',
		'unit.query.CommentOwnerGuardSliceTest#testReplacingTheSeparatingCodeIsAccepted :: control',
		'unit.query.CommentRewriteSliceTest#testCallerSuppliedGutterIsNotDoubled :: base',
		'unit.query.CommentRewriteSliceTest#testOverWideReplacementAllowedWithFlag :: control',
		'unit.query.CondBranchSplitTest#testBranchDeclResolvesFromAfterTheRegion :: control',
		'unit.query.CondBranchSplitTest#testOuterDeclResolvesInsideBranch :: control',
		'unit.query.DocOwnerGuardSliceTest#testInsertAboveTheDocIsAccepted :: control',
		'unit.query.ExtractInterfaceSliceTest#testANonCanonicalSourceIsNotReformatted :: control',
		'unit.query.ExtractInterfaceSliceTest#testAlreadyImplementsRefused :: base',
		'unit.query.ExtractInterfaceSliceTest#testAnUntypedBodyIsCutOffLikeAnyOther :: base',
		'unit.query.ExtractInterfaceSliceTest#testQualifiedSameNameDoesNotBlock :: base',
		'unit.query.ExtractInterfaceSliceTest#testSecondInterfaceStillExtracts :: base',
		'unit.query.ImplicitStdScopeTest#testConfigLessUnresolvableImportStaysInfoAndSurvivesFix :: control',
		'unit.query.LexicalRegionsSeamTest#testTheEngineNamesNoHaxeGrammarRuleType :: base',
		'unit.query.MakeFinalSliceTest#testHalfIteratorShapeStillFinal :: control',
		'unit.query.MetaElementSpanSliceTest#testRemoveConditionalModifierRegionStillTakesTheMember :: control',
		'unit.query.MetaElementSpanSliceTest#testRemoveDeclKeywordStillFoldsItsPrefixRun :: control,base',
		'unit.query.MetaElementSpanSliceTest#testRemoveModifierStillTakesTheMemberAndItsMeta :: control,base',
		'unit.query.MetaElementSpanSliceTest#testRemoveModifierStillTakesTheMemberDoc :: control',
		'unit.query.MetaElementSpanSliceTest#testRemoveModuleDeclStillTakesItsDocAndMeta :: control,base',
		'unit.query.MetaElementSpanSliceTest#testRemoveModuleModifierStillTakesTheType :: control,base',
		'unit.query.MoveCanonicalOutputSliceTest#testMoveLeavesANonCanonicalSourceUnformatted :: control',
		'unit.query.MoveFamilyCaptureTest#testABareWildcardCallerIsRepointedByteIdentically :: base',
		'unit.query.MoveFamilyCaptureTest#testALocalShadowKeepsItsBareReadByteIdentically :: base',
		'unit.query.MoveFamilyCaptureTest#testARivalWildcardKeepsItsBareCallerByteIdentically :: base',
		'unit.query.MoveFamilyCaptureTest#testASubModuleMoveRepointsNoWildcardCallerByteIdentically :: base',
		'unit.query.MoveGuardedImportCarryTest#testAModuleImportCarriesOnlyWhenTheModuleIsInsideTheScope :: base',
		'unit.query.MoveGuardedImportCarryTest#testASubModuleTypeKeepsItsModuleImportInTheDestinationsOwnPackage :: base',
		'unit.query.MoveMemberSliceTest#testARedundantMemberLevelAccessIsNotWritten :: control',
		'unit.query.MoveMemberSliceTest#testCarriedImportCollidingWithADestinationBindingRefused :: control',
		'unit.query.MoveSymbolSliceTest#testAnAmbientTopLevelDependencyIsNotACollision :: base',
		'unit.query.MoveSymbolSliceTest#testCuttingAMiddleDeclarationLeavesExactlyOneSeparator :: base',
		'unit.query.MoveSymbolSliceTest#testCuttingTheLastDeclarationOfAModuleTakesItsSeparator :: base',
		'unit.query.MoveSymbolSliceTest#testPrivateSiblingMainTypeIsNotABinding :: base',
		'unit.query.NameMentionScanTest#testACommentOnlyDestinationMentionDoesNotContestTheCarry :: control',
		'unit.query.NameMentionScanTest#testAStringSpellingTheQualifiedPathStillRefusesWhileACommentDoesNot :: control',
		'unit.query.NewFileSliceTest#testImportsSectionTakesStatements :: base',
		'unit.query.PatchSliceTest#testAbsentFragmentKeepsTheVerbatimRemedy :: control,base',
		'unit.query.PatchSliceTest#testDocCodeSampleIndentationSurvives :: base',
		'unit.query.PatchSliceTest#testDocPayloadWithASpaceGutterApplies :: base',
		'unit.query.PatchSliceTest#testInPlaceEditUnderADocAccepted :: base',
		'unit.query.PatchSliceTest#testInsertAfterAPlainBannerAccepted :: base',
		'unit.query.PatchSliceTest#testInsertAheadOfADocumentedMemberThatIsAlsoRenamedRefused :: base',
		'unit.query.PatchSliceTest#testInsertAheadOfTheDocBlockAccepted :: control',
		'unit.query.PatchSliceTest#testMidLineFragmentByteExactStillApplies :: control,base',
		'unit.query.PatchSliceTest#testWholeLineFragmentIsIndentationInsensitive :: control,base',
		'unit.query.RemoveMemberSliceTest#testTypedefFieldIsRemovable :: control',
		'unit.query.RenameSliceTest#testNamedFunctionLiteralParameterRenamesApartFromAnOuterLocal :: control',
		'unit.query.ResolutionLibraryCacheTest#testLibraryParseIsSharedAcrossRuns :: vacuity',
		'unit.query.SetDocSliceTest#testFlushBulletSurvives :: base',
		'unit.query.SetModifierSliceTest#testAConditionalRegionOutsideTheKeywordRunIsStillServed :: control',
		'unit.query.SetModifierSliceTest#testAnEnumAbstractMemberStillTakesPublic :: control',
		'unit.query.ShardPlanTest#testTheNoRegistrationsRefusalNamesTheOtherDoor :: vacuity',
		'unit.query.SymbolIndexLayerSeamTest#testEachLayerOwnsItsQuestionsAndTheIndexDeclaresNone :: base',
		'unit.query.SymbolIndexRunMemoSliceTest#testConfinementGateReadsTheIndexGrantSlot :: base',
		'unit.query.SymbolIndexRunMemoSliceTest#testSupertypeNameUnionIsBuiltOncePerIndex :: base',
		'unit.query.SymbolIndexSliceTest#testIsExternUnconditionalControls :: control',
		'unit.query.SymbolIndexSliceTest#testTypedefAnonFieldsAreMembers :: control',
		'unit.query.TypeResolverSliceTest#testAReadBeforeAReDeclarationKeepsItsOwnProof :: control'
	];

	/** A named arm in the prose is an `arm` claim, and nothing else. */
	@:pin('control')
	@:killer('M-CLAIM-NOKINDS')
	public function testAnArmSentenceIsReadAsAnArmClaim(): Void {
		Assert.same([], ProseClaims.kindsOf(PLAIN_SENTENCE), 'ordinary prose claims nothing, so the fixture reaches the predicate');
		Assert.same([ProseClaims.ARM], ProseClaims.kindsOf(ARM_SENTENCE), 'the arm sentence is one arm claim');
	}

	/** A claim that WRAPS across a doc-comment line break is still one claim. */
	@:pin('control')
	@:killer('M-CLAIM-RAW-DOC')
	public function testAWrappedClaimSurvivesTheLineBreak(): Void {
		Assert.same([ProseClaims.ARM], ProseClaims.kindsOf(ARM_SENTENCE), 'the unwrapped sentence reads as an arm claim either way');
		Assert.same(
			[ProseClaims.ARM],
			ProseClaims.kindsOf(WRAPPED_ARM_SENTENCE),
			'`killed by` split over a gutter is the same claim — a line-oriented search cannot see it'
		);
	}

	/** A sentence saying no arm kills the fixture is not a fixture owing an arm. */
	@:pin('control')
	@:killer('M-CLAIM-NEG-BLIND')
	public function testANegatedArmSentenceClaimsNothing(): Void {
		Assert.same([ProseClaims.ARM], ProseClaims.kindsOf(ARM_SENTENCE), 'the positive sentence still reads as a claim');
		Assert.same([], ProseClaims.kindsOf(NEGATED_ARM_SENTENCE), 'and its denial is not one');
	}

	/** `control` about code is not a fixture calling itself a control. */
	@:pin('control')
	@:killer('M-CLAIM-CODE-BLIND')
	public function testTheCodeSenseOfControlIsNotAControlClaim(): Void {
		Assert.same([ProseClaims.CONTROL], ProseClaims.kindsOf(CONTROL_SENTENCE), 'the role sense is a claim');
		Assert.same([], ProseClaims.kindsOf(CODE_SENTENCE), 'and the code sense is not');
	}

	/** An annotation retires the claim it records — and only that one. */
	@:pin('control')
	@:killer('M-CLAIM-ALL-RECORDED')
	public function testAnAnnotationRetiresOnlyTheClaimItRecords(): Void {
		Assert.same(
			[], ProseClaims.unrecorded(ARM_SENTENCE, [], ['M-CLAIM-NOKINDS']), 'a @:killer records the arm claim, so nothing is owed'
		);
		Assert.same(
			[ProseClaims.ARM],
			ProseClaims.unrecorded(ARM_SENTENCE, ['seam'], []), 'and a pin under another role records nothing about an arm'
		);
	}

	/** A control claim needs the CONTROL role, not merely some pin. */
	@:pin('control')
	@:killer('M-CLAIM-ALL-RECORDED')
	public function testAControlClaimNeedsTheControlRole(): Void {
		Assert.same([], ProseClaims.unrecorded(CONTROL_SENTENCE, ['control'], []), 'the control role records the control claim');
		Assert.same(
			[ProseClaims.CONTROL],
			ProseClaims.unrecorded(CONTROL_SENTENCE, ['guard'], []), 'another role names a different job and records nothing'
		);
	}

	/**
	 * The base-redness and vacuity kinds have no annotation, so they are
	 * censused and never retired.
	 */
	@:pin('control')
	@:killer('M-CLAIM-NOKINDS')
	public function testTheTwoUnrecordableKindsStayOnTheList(): Void {
		Assert.same([], ProseClaims.kindsOf(PLAIN_SENTENCE), 'ordinary prose claims nothing, so the fixture reaches the predicate');
		Assert.same(
			[ProseClaims.BASE],
			ProseClaims.unrecorded('RED at base — the window started at the `public` line.', ['control'], ['M-CLAIM-NOKINDS']),
			'no annotation answers a base-redness claim, whatever the fixture carries'
		);
	}

	/**
	 * The snapshot. Not a discrimination and not pinned as one: it is derived
	 * from the same tree the macro walks, so it can only report that the list
	 * moved — which is exactly what a ratchet is for.
	 */
	public function testTheProseCensusMatchesItsBaseline(): Void {
		Assert.same(BASELINE, TestRegistry.claims(), 'regenerate with `node bin/test.js --list-claims` after rebuilding it');
	}

}
