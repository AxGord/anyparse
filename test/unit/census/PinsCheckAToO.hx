package unit.census;

/**
 * Part of the pin census `unit.PinCensusParityTest` compares with `TestRegistry.pins()`:
 * every pin that sorts before `'unit.check.P'`: the suite-hygiene classes of the root
 * package (`unit.<Class>` sorts before `unit.check`) and the rule tests `unit.check.A*`..`O*`
 *
 * SORTED, in code-unit order (`TestRegistry.pins()` sorts so): a new pin goes into the part
 * whose range holds it, at its sorted place — `hxq add-element test/unit/census/PinsCheckAToO.hx --sorted
 * --select 'FinalMember:PINS >> ArrayExpr' "'<entry>'" --write`. The parts concatenate in
 * range order, so an entry in the wrong part fails the census as a misordered list.
 */
@:nullSafety(Strict)
final class PinsCheckAToO {

	public static final PINS: Array<String> = [
		'unit.FixtureCompileCacheTest#testACompileWritingIntoItsCwdIsNotRecorded :: control :: M-FIXTURE-CACHE-CWD-WRITE',
		'unit.MutationArmAddressTest#testEveryDeclaredArmAddressesALiveMember :: control :: M-ARM-PATH-FLAT,M-ARM-KIND-UNSPELLED',
		'unit.MutationArmAddressTest#testEveryFragmentArmStillCutsItsNode :: control :: M-ARM-FRAGMENT-NONE',
		'unit.MutationArmAddressTest#testTheDeferredArmsAreTheOnesTheWalkAnswersFor :: control :: M-ARM-PATH-FLAT',
		'unit.MutationArmsTest#testADuplicateArmNameIsRefused :: guard :: ',
		'unit.MutationArmsTest#testAForcedCutWithANonDefaultKindIsRefused :: control :: M-ARM-ROW-OK',
		'unit.MutationArmsTest#testAForcedRowWithFragmentListsIsRefused :: control :: M-ARM-ROW-OK',
		'unit.MutationArmsTest#testAKindedArmSpellsItsKindInTheAddress :: control :: M-ARM-KIND-UNSPELLED',
		'unit.MutationArmsTest#testAMalformedFragmentListIsNamedByItsKeyAlone :: control :: M-ARM-ROW-OK',
		'unit.MutationArmsTest#testAMismatchedPairCountIsRefused :: control :: M-ARM-ROW-OK',
		'unit.MutationArmsTest#testAModulePathBecomesTheTwoCandidateFiles :: control :: M-ARM-PATH-FLAT',
		'unit.MutationArmsTest#testAMultiPairCutCarriesEveryFragment :: guard :: ',
		'unit.MutationArmsTest#testANonJsonTableIsOneComplaint :: guard :: ',
		'unit.MutationArmsTest#testAPairThatChangesNothingIsRefused :: control :: M-ARM-ROW-OK',
		'unit.MutationArmsTest#testARowDeclaringBothCutsIsRefused :: control :: M-ARM-ROW-OK',
		'unit.MutationArmsTest#testARowDeclaringNeitherCutIsRefused :: control :: M-ARM-ROW-OK,M-ARM-ANYNAME',
		'unit.MutationArmsTest#testAWellFormedTableAnswersByName :: control :: M-ARM-ANYNAME',
		'unit.MutationArmsTest#testAnEmptyFragmentArrayIsRefused :: control :: M-ARM-ROW-OK',
		'unit.MutationArmsTest#testAnUndeclaredNameResolvesToNoArm :: control :: M-ARM-ANYNAME',
		'unit.MutationArmsTest#testRenderNamesTheMemberAndTheCut :: guard :: ',
		'unit.ProseClaimCensusTest#testAControlClaimNeedsTheControlRole :: control :: M-CLAIM-ALL-RECORDED',
		'unit.ProseClaimCensusTest#testANegatedArmSentenceClaimsNothing :: control :: M-CLAIM-NEG-BLIND',
		'unit.ProseClaimCensusTest#testAWrappedClaimSurvivesTheLineBreak :: control :: M-CLAIM-RAW-DOC',
		'unit.ProseClaimCensusTest#testAnAnnotationRetiresOnlyTheClaimItRecords :: control :: M-CLAIM-ALL-RECORDED',
		'unit.ProseClaimCensusTest#testAnArmSentenceIsReadAsAnArmClaim :: control :: M-CLAIM-NOKINDS',
		'unit.ProseClaimCensusTest#testTheCodeSenseOfControlIsNotAControlClaim :: control :: M-CLAIM-CODE-BLIND',
		'unit.ProseClaimCensusTest#testTheTwoUnrecordableKindsStayOnTheList :: control :: M-CLAIM-NOKINDS',
		'unit.check.AmbientImportRulesTest#testAGovernedSetThatCannotBeEstablishedWithholdsEveryVerdict :: control :: '
			+ 'M-AMBIENT-GOVERNANCE-COMPLETE',
		'unit.check.AmbientImportRulesTest#testAGuardedBinderInTheNearestGroupKeepsTheOwnStatement :: control :: '
			+ 'M-AMBIENT-REDUNDANT-GUARDED-SKIP',
		'unit.check.AmbientImportRulesTest#testASiblingTheNearerGroupDecidesKeepsTheOwnStatement :: control :: M-IMPORT-LEAF-ONLY-NAMES',
		'unit.check.AmbientImportRulesTest#testAnAmbientImportAModuleUnderItUsesIsNotReported :: control :: M-AMBIENT-GOVERNANCE-BLIND',
		'unit.check.AmbientImportRulesTest#testAnAmbientImportNoModuleUnderItUsesIsStillReported :: control :: M-AMBIENT-GOVERNANCE-SHORT',
		'unit.check.AmbientImportRulesTest#testAnOwnStatementBindingAConstructorIsKeptBesideTheAmbientCopy :: control :: '
			+ 'M-REDUNDANT-AMBIENT-VALUES',
		'unit.check.AmbientImportRulesTest#testAnOwnUsingIsKeptWhereAnotherUsingCouldTakeItsPosition :: control :: '
			+ 'M-AMBIENT-REDUNDANT-USING-POSITION',
		'unit.check.AmbientImportRulesTest#testTheDeclaringModuleIsAReaderOfAnAmbientUsingOfItself :: control :: '
			+ 'M-AMBIENT-DECLARER-READS-USING',
		'unit.check.AmbientImportRulesTest#testTheGovernedSetIsReadEvenWhenTheRunWasGivenTheAmbientSourceAlone :: control :: '
			+ 'M-AMBIENT-GOVERNANCE-BLIND',
		'unit.check.AmbientImportRulesTest#testTheModuleAnAmbientStatementImportsIsNotOneOfItsReaders :: control :: '
			+ 'M-AMBIENT-DECLARER-READS',
		'unit.check.AmbientImportSubtypeShieldTest#testAWrittenAliasIsPinnedToNothingRatherThanToItsNamesake :: control :: '
			+ 'M-AMBIENT-ALIAS-PINNED',
		'unit.check.AmbientImportSubtypeShieldTest#testTheAmbientlyImportedTypeKeepsTheShieldAndTheNamesakeLosesIt :: control :: '
			+ 'M-AMBIENT-IMPORT-BAND',
		'unit.check.AmbientImportSubtypeShieldTest#testTheChainIsReadEvenWhenItsFileIsOutsideTheAnalysedSet :: control :: '
			+ 'M-AMBIENT-IMPORT-BAND',
		'unit.check.AmbientImportSubtypeShieldTest#testTheWildcardTierShieldsTheTypeTheSupertypeReallyNames :: control :: '
			+ 'M-AMBIENT-IMPORT-BAND',
		'unit.check.AnonTypeDupCheckTest#testAGroupIsAnchoredWhereTheRuleIsEnabled :: control :: M-ANON-ANCHOR-UNGATED',
		'unit.check.AnonTypeDupCheckTest#testEachFileHeldToItsOwnChainThreshold :: control :: M-ANON-FIRST-FILE-CONFIG',
		'unit.check.AsymmetricBranchBracesCheckTest#testFixBracesTheBareElse :: control :: M-ASYM-FIX-NO-EDIT',
		'unit.check.AsymmetricBranchBracesCheckTest#testFixBracesTheWholeElseIfChain :: control :: M-ASYM-FIX-CHAIN-TAIL-ONLY',
		'unit.check.AsymmetricBranchBracesCheckTest#testFixLeavesAConditionalRegionBare :: control :: M-ASYM-FIX-OPEN-TAIL-ANY',
		'unit.check.AsymmetricBranchBracesCheckTest#testFixLeavesADeclarationBare :: control :: M-ASYM-FIX-DECL',
		'unit.check.AsymmetricBranchBracesCheckTest#testFixLeavesANestedPairToTheNextPass :: control :: M-ASYM-FIX-NESTED-OVERLAP',
		'unit.check.AsymmetricBranchBracesCheckTest#testFixTerminatesAnUnterminatedExpression :: control :: '
			+ 'M-ASYM-FIX-NO-TERMINATOR-ADDED,M-ASYM-FIX-UNTERMINATED',
		'unit.check.AvoidDynamicBagFixTest#testANullableValueIsNeverTypedByItsBareWrapper :: control :: M-BAG-NULL-OUTER',
		'unit.check.AvoidDynamicBagFixTest#testAnInitializerOfAnotherTypeKeepsTheDeclaration :: control :: M-BAG-INITIALIZER',
		'unit.check.AvoidDynamicCheckTest#testDynamicInsideIntersectionOrConditionalArgumentFlagged :: control :: '
			+ 'M-AVOIDDYN-COMPOSITE-SKIPPED',
		'unit.check.AvoidDynamicRiskyFixE2ETest#testAFixNeverLandsWhereItsRuleIsDisabled :: control :: '
			+ 'M-COLLECT-NO-ENABLEMENT,M-FIXVERIFY-ENABLEMENT-DROPPED',
		'unit.check.AvoidDynamicRiskyFixE2ETest#testTheRunResolverGatesTheScannedFiles :: control :: M-FIXVERIFY-DISCOVERS-CONFIG',
		'unit.check.AvoidDynamicRiskyFixE2ETest#testTheRunResolverReachesTheCheckOptions :: control :: M-FIXVERIFY-CHECK-DISCOVERS-CONFIG',
		'unit.check.BuiltinFixClassCensusTest#testEveryDeclaredNoAutofixRuleAnswersNoEdit :: control :: M-NO-AUTOFIX-STILL-EDITS',
		'unit.check.BuiltinFixClassCensusTest#testNoAutofixReasonIsNotTheRuleNameReadBack :: control :: '
			+ 'M-NO-AUTOFIX-REASON-IS-THE-RULE-NAME',
		'unit.check.BuiltinFixClassCensusTest#testNoDeclaredNoAutofixRuleCarriesAFixSeam :: guard :: ',
		'unit.check.CollapseNestedSwitchCheckTest#testUnprovenBinderRefused :: control :: M-COLLAPSE-BINDER-UNPROVEN',
		'unit.check.CommentWidthCheckTest#testABacktickSpanIsNeverSplit :: control :: M-COMMENT-REFLOW-SPLITS-CODE-SPAN',
		'unit.check.CommentWidthCheckTest#testACommentInARawCondRegionIsReportOnly :: control :: M-COMMENT-WIDTH-OPAQUE-OPEN',
		'unit.check.CommentWidthCheckTest#testAFencedCodeSampleIsReportOnly :: control :: M-COMMENT-WIDTH-FENCE-BLIND',
		'unit.check.CommentWidthCheckTest#testAOneLineBlockOverByItsCloserIsReflowed :: control :: M-COMMENT-WIDTH-CLOSER-UNSEEN',
		'unit.check.CommentWidthCheckTest#testAProseLineWithATwinInsideAFenceIsStillFixable :: control :: '
			+ 'M-COMMENT-WIDTH-PROTECTION-BY-TEXT',
		'unit.check.CommentWidthCheckTest#testATabAlignedRowIsReportOnlyAndSaysSo :: control :: M-COMMENT-REFLOW-TAB-ROW',
		'unit.check.CommentWidthCheckTest#testATableRowIsReportOnlyAndSaysSo :: control :: M-COMMENT-REFLOW-UNSAFE-LINES',
		'unit.check.CommentWidthCheckTest#testATrailingCommentBehindOverWideCodeIsNotThisRulesFinding :: control :: '
			+ 'M-COMMENT-WIDTH-CODE-BLIND',
		'unit.check.CommentWidthCheckTest#testATrailingCommentIsReportOnly :: control :: M-COMMENT-WIDTH-TRAILING-WRAPPED',
		'unit.check.CommentWidthCheckTest#testCodeOnBothSidesOfAShortCommentIsNotThisRulesFinding :: control :: '
			+ 'M-COMMENT-WIDTH-CODE-BLIND',
		'unit.check.CommentWidthCheckTest#testCommentedOutCodeIsReportOnlyAndSaysSo :: control :: M-COMMENT-REFLOW-CODE-SHAPED',
		'unit.check.CommentWidthCheckTest#testOnlyTheLinesTheViolationsNameAreReflowed :: control :: M-COMMENT-WIDTH-PROTECTION-OFF',
		'unit.check.CommentWidthCheckTest#testTheConfiguredWidthIsRead :: control :: M-COMMENT-WIDTH-CONFIG-BLIND',
		'unit.check.CommentWidthCheckTest#testTheFixReflowsIntoTheWidthWordForWord :: control :: M-COMMENT-REFLOW-ABSENT',
		'unit.check.CommentWidthCheckTest#testTwoIdenticalWideLinesAreTwoLines :: control :: M-COMMENT-WIDTH-PROTECTION-BY-TEXT',
		'unit.check.ComparisonToBooleanCheckTest#testFieldAccessBoolMemberFlagged :: control :: M-PATHWALK-NULL',
		'unit.check.ComparisonToBooleanCheckTest#testResolvedMemberTypedByTypeParamSkipped :: control :: '
			+ 'M-CMPBOOL-RESOLVED-TYPE-PARAM-BLIND',
		'unit.check.ComparisonToBooleanCheckTest#testTypeParamSpelledLikeBoolSkipped :: control :: M-NULLITY-TYPE-PARAM-BLIND',
		'unit.check.ComplexityCheckTest#testWhileExpressionCounted :: control :: M-VOCAB-WHILE-EXPR-NOT-BRANCH',
		'unit.check.ConfiguredIdiomE2ETest#testTheOracleRevertsWhatTheRuleCannotProve :: control :: M-EVENT-NO-MISMATCH',
		'unit.check.CrossScopeSoundnessTest#testAnUnreadableReflectiveFileLicensesNothingExtra :: control :: '
			+ 'M-REFLECTION-UNREADABLE-BLIND,M-INLINE-UNREADABLE-BLIND',
		'unit.check.CrossScopeSoundnessTest#testNarrowReportFindsNothingTheWideRunDoesNot :: control :: M-CONFINEMENT-REPORT-INDEX-DEAD',
		'unit.check.CrossScopeSoundnessTest#testNarrowReportWritesNothingTheWideRunRefuses :: control :: '
			+ 'M-REFLECTION-REPORT-INDEX-DELETE,M-INLINE-SUBTYPE-REPORT-INDEX,M-INLINE-REFLECT-REPORT-SCOPE,'
			+ 'M-ORPHAN-ACCESSOR-REPORT-SCOPE,M-MAPVALUE-SUBTYPE-REPORT-INDEX,M-TYPEDTHROW-CATCH-REPORT-ONLY',
		'unit.check.CrossScopeSoundnessTest#testTheScopeHalfHoldingAReflectiveStringDoesNotMatter :: control :: '
			+ 'M-REFLECTION-SCOPE-PROJECT-ONLY',
		'unit.check.DeadNullCoalescingTest#testBoolLocalProofKeepsNoFixUnderNullSafety :: control :: '
			+ 'M-DNC-UNSEEN-DROPPED,M-NSG-GATE-NEVER,M-DNC-DECLINED-FIXED',
		'unit.check.DeadNullCoalescingTest#testDirectGuardKeepsTheFixUnderNullSafety :: control :: M-DSN-UNSEEN-ALL,M-NSG-VISIBLE-IGNORED',
		'unit.check.DeadNullCoalescingTest#testLoopBinderShadowsTheOuterProof :: control :: M-NULLFLOW-BINDER-BLIND',
		'unit.check.DeadNullGuardTest#testBoolAliasProofKeepsTheFixWithoutNullSafety :: control :: M-DSN-NULLSAFE-ALWAYS',
		'unit.check.DeadNullGuardTest#testEveryUnseenProofKeepsNoFixUnderNullSafety :: control :: '
			+ 'M-DNG-UNSEEN-DROPPED,M-NSG-GATE-NEVER,M-DNG-DECLINED-FIXED',
		'unit.check.DeadNullGuardTest#testVisibleProofKeepsTheFixUnderNullSafety :: control :: M-DSN-UNSEEN-ALL,M-NSG-VISIBLE-IGNORED',
		'unit.check.DeadSafeNavTest#testAliasProofKeepsNoFixUnderNullSafety :: control :: M-DSN-UNSEEN-DROPPED',
		'unit.check.DeadSafeNavTest#testAssignmentInsideACallKeepsTheFix :: control :: M-DSN-OWNS-NONE',
		'unit.check.DeadSafeNavTest#testBoolLocalProofKeepsNoFixUnderNullSafety :: control :: M-DSN-UNSEEN-DROPPED',
		'unit.check.DeadSafeNavTest#testBoolLocalProofKeepsTheFixWithoutNullSafety :: control :: M-DSN-NULLSAFE-ALWAYS',
		'unit.check.DeadSafeNavTest#testCaseCapturesShadowTheOuterProof :: control :: M-NULLFLOW-CASE-BINDER-BLIND',
		'unit.check.DeadSafeNavTest#testCatchVariableShadowsTheOuterProof :: control :: M-NULLFLOW-CATCH-BINDER-BLIND',
		'unit.check.DeadSafeNavTest#testCommentedMacroKeepsTheFix :: control :: M-DSN-HXML-ALWAYS-ON,M-DSN-HXML-COMMENT-READ',
		'unit.check.DeadSafeNavTest#testDirectGuardKeepsTheFixUnderNullSafety :: control :: M-DSN-UNSEEN-ALL',
		'unit.check.DeadSafeNavTest#testGlobalMetadataMacroKeepsNoFix :: control :: M-DSN-MACRO-BLIND',
		'unit.check.DeadSafeNavTest#testIncludedHxmlIsRead :: control :: M-DSN-HXML-INCLUDE-SKIPPED',
		'unit.check.DeadSafeNavTest#testJoinWithOneUnseenArmKeepsNoFix :: control :: M-DSN-JOIN-EITHER',
		'unit.check.DeadSafeNavTest#testKeyValueBinderShadowsTheOuterProof :: control :: M-NULLFLOW-CHILD-BINDER-BLIND',
		'unit.check.DeadSafeNavTest#testLoneArmBodyProofKeepsNoFix :: control :: M-DSN-LONE-ARM-KEEPS-BODY',
		'unit.check.DeadSafeNavTest#testLoneArmConditionProofKeepsTheFix :: control :: M-DSN-LONE-ARM-HIDES-ALL',
		'unit.check.DeadSafeNavTest#testLoneSwitchBranchProofKeepsNoFix :: control :: M-DSN-LONE-BRANCH-KEEPS-BODY',
		'unit.check.DeadSafeNavTest#testLoopBinderShadowsTheOuterProof :: control :: M-NULLFLOW-BINDER-BLIND',
		'unit.check.DeadSafeNavTest#testNonNullAssignmentMakesTheProofVisible :: control :: M-DSN-ASSIGN-KEEPS-UNSEEN',
		'unit.check.DeadSafeNavTest#testOracleMacroNullSafetyKeepsNoFix :: control :: M-DSN-MACRO-BLIND',
		'unit.check.DeadSafeNavTest#testOuterProofSurvivesTheShadowingLoop :: control :: M-NULLFLOW-SHADOW-NO-RESTORE',
		'unit.check.DeadSafeNavTest#testPlainOracleBuildKeepsTheFix :: control :: M-DSN-HXML-ALWAYS-ON',
		'unit.check.DeadSafeNavTest#testProofBeforeTryKeepsTheFix :: control :: M-DSN-TRY-HIDES-ALL',
		'unit.check.DeadSafeNavTest#testSafeNavComparisonProofKeepsNoFixUnderNullSafety :: control :: M-DSN-UNSEEN-DROPPED',
		'unit.check.DeadSafeNavTest#testTryProofKeepsNoFix :: control :: M-DSN-TRY-KEEPS-ALL',
		'unit.check.DeadSafeNavTest#testTwoLiveArmsKeepTheFix :: control :: M-DSN-JOIN-HIDES-ALL',
		'unit.check.DeadSafeNavTest#testTwoLiveSwitchBranchesKeepTheFix :: control :: M-DSN-JOIN-HIDES-ALL',
		'unit.check.DeadSafeNavTest#testUnreadLibraryKeepsNoFix :: control :: M-DSN-MACRO-BLIND,M-DSN-HXML-LIB-PLAIN',
		'unit.check.DeadSafeNavTest#testUnreadableOracleHxmlKeepsNoFix :: control :: M-DSN-HXML-UNREADABLE-PLAIN',
		'unit.check.DeadSafeNavTest#testVisibleProofSurvivesAnUnseenRenarrowing :: control :: M-DSN-RENARROW-HIDES',
		'unit.check.DeadSafeNavTest#testWrittenNameIsNotRestored :: control :: M-NULLFLOW-SHADOW-RESTORES-WRITTEN',
		'unit.check.DeadStoreTest#testFixRefusesAProjectShadowOfAStdType :: control :: M-STD-SHADOW-IGNORED',
		'unit.check.DeadStoreTest#testFixStripsStringMethodAndClockInitializers :: control :: M-DEADSTORE-OWN-PURITY',
		'unit.check.DefaultRepeatedArgumentCheckTest#testArgumentPastAnOptionalParameterNotCounted :: control :: M-DRA-SKIPPED-SLOT',
		'unit.check.DefaultRepeatedArgumentCheckTest#testMaybeNullArgumentSiteBlocks :: control :: M-DEFAULT-ARG-NONNULL-ANY',
		'unit.check.DefaultRepeatedArgumentCheckTest#testMiddleArgumentNeverDropped :: control :: M-DRA-MIDDLE-ARGUMENT',
		'unit.check.DefaultRepeatedArgumentCheckTest#testNullArgumentSiteBlocks :: control :: M-DEFAULT-ARG-NULL-SITE-ADMITTED',
		'unit.check.DefaultRepeatedArgumentCheckTest#testNullValuedConstantSiteBlocks :: control :: M-DEFAULT-ARG-NULL-CONST-NONNULL',
		'unit.check.DefaultRepeatedArgumentCheckTest#testUnresolvedNullSiteBlocks :: control :: M-DEFAULT-ARG-UNRESOLVED-NULL-IGNORED',
		'unit.check.DocLengthCheckTest#testOnlyADocBlockIsMeasured :: control :: M-DOC-LENGTH-ANY-COMMENT',
		'unit.check.DocLengthCheckTest#testTheDeclaredMaximumIsRead :: control :: M-DOC-LENGTH-CONFIG-BLIND',
		'unit.check.DocMeasurementClaimCheckTest#testANumericContractIsNotAReading :: control :: M-DOC-CLAIM-BARE-NUMBER',
		'unit.check.DocMeasurementClaimCheckTest#testAPercentageShareIsAReadingAndTheRemainderOperatorIsNot :: control :: '
			+ 'M-DOC-CLAIM-PERCENT-REMAINDER-BLIND',
		'unit.check.DocMeasurementClaimCheckTest#testAPointerAtTheRecordIsNotTheRecord :: control :: M-DOC-CLAIM-REFERENCE-BLIND',
		'unit.check.DocMeasurementClaimCheckTest#testAReadingInsideAStringLiteralIsData :: guard :: ',
		'unit.check.DocMeasurementClaimCheckTest#testAnArrowNeedsNumbersOnBothSides :: control :: M-DOC-CLAIM-ARROW-ANY',
		'unit.check.DocMeasurementClaimCheckTest#testTheRecordingVerbMidClauseNeedsANumberOnItsLine :: control :: '
			+ 'M-DOC-CLAIM-VERB-UNGATED',
		'unit.check.DocMeasurementClaimCheckTest#testTheRecordingVerbOpeningAClauseIsAReading :: control :: M-DOC-CLAIM-CLAUSE-BLIND',
		'unit.check.DuplicateCodeCheckTest#testABareDeclarationRunIsNotAClone :: control :: M-DUP-CODE-BARE-RUN-OFF',
		'unit.check.DuplicateCodeCheckTest#testABareRunWithOneCallIsAClone :: guard :: ',
		'unit.check.DuplicateCodeCheckTest#testALiteralInteriorDifferenceIsNotACloneWhileItsLayoutTwinIs :: control :: '
			+ 'M-DUP-CODE-NORM-KEY',
		'unit.check.DuplicateCodeCrossFileCheckTest#testADisabledCopyTakesTheAnchor :: control :: M-DUP-ANCHOR-UNGATED',
		'unit.check.DuplicateCodeRenamedCheckTest#testABareDeclarationRunIsNotAClone :: control :: M-DUP-CODE-BARE-RUN-OFF',
		'unit.check.DuplicateCodeRenamedCheckTest#testABareRunWithOneCallIsAClone :: guard :: ',
		'unit.check.DuplicateCodeRenamedCheckTest#testALocalsOnlyRenamingIsAClone :: control :: M-DUP-CODE-RENAMED-BINDERS',
		'unit.check.DuplicateCodeRenamedCheckTest#testDeclarationsWhoseBytesAreMostlyTheirNamesAreNotAClone :: control :: '
			+ 'M-DUP-CODE-RENAMED-GATE-RAW',
		'unit.check.EffectiveRulesTest#testADefaultOffRuleRunsOnlyWhereAConfigEnablesIt :: control :: M-EFFECTIVE-IGNORES-DEFAULT-OFF',
		'unit.check.EffectiveRulesTest#testALanguageVersionBelowTheFixDropsTheRule :: control :: M-EFFECTIVE-IGNORES-VERSION',
		'unit.check.EffectiveRulesTest#testANestedConfigFoldsItsAncestors :: control :: M-EFFECTIVE-IGNORES-CONFIG,M-CHAIN-NEAREST-ONLY',
		'unit.check.EffectiveRulesTest#testAPathARuleExcludesIsOffForThatFileOnly :: control :: '
			+ 'M-GATE-TS-EXCLUDE-BLIND,M-GATE-AD-EXCLUDE-BLIND',
		'unit.check.EffectiveRulesTest#testARuleWithNothingToLookForIsOff :: control :: M-GATE-TS-SINKS-BLIND,M-EFFECTIVE-IGNORES-FILEGATE',
		'unit.check.EffectiveRulesTest#testFilesGroupByChainNotByDirectory :: control :: M-EFFECTIVE-GROUPS-PER-DIR',
		'unit.check.EffectiveRulesTest#testInheritFalseEndsTheChain :: control :: M-CHAIN-IGNORES-INHERIT',
		'unit.check.EffectiveRulesTest#testOptionsThatSwitchEveryFindingOffAreANoop :: control :: M-GATE-NOOP-DOC,M-GATE-NOOP-UNDERSCORE',
		'unit.check.EffectiveRulesTest#testTheChainStopsAtTheProjectRoot :: control :: M-CHAIN-UNBOUNDED',
		'unit.check.EffectiveRulesTest#testTheListingOpensWithTheHeaderToolingDetects :: control :: M-EFFECTIVE-RENDER-HEADER',
		'unit.check.EffectiveRulesTest#testTheRunSkipsWhatTheListingReportsOff :: control :: M-GATE-COLLECT-BYPASS',
		'unit.check.EmptyBlockCheckTest#testDeclinedSitesSayWhy :: control :: M-EMPTY-BLOCK-NO-DECLINE',
		'unit.check.EmptyBlockCheckTest#testDrainLoopNotFlagged :: control :: M-EMPTY-BLOCK-DRAIN-LOOP',
		'unit.check.ExplicitLocalTypeOracleE2ETest#testTheDisplayServerDiesWithItsDriver :: control :: M-DISPLAY-SERVER-UNTETHERED',
		'unit.check.ExplicitTypeCheckTest#testFixMacroFunctionReturningQuotationIsExpr :: control :: M-EXPLICIT-TYPE-MACRO-NO-PROOF',
		'unit.check.ExplicitTypeCheckTest#testFixMacroFunctionTernaryAndContextError :: control :: M-EXPLICIT-TYPE-MACRO-NO-COMPANION',
		'unit.check.ExplicitTypeCheckTest#testMacroFunctionShadowedContextDeclines :: control :: M-EXPLICIT-TYPE-MACRO-SHADOW',
		'unit.check.ExplicitTypeCheckTest#testMacroFunctionWithUnprovenReturnDeclines :: control :: M-EXPLICIT-TYPE-MACRO-ANY-RETURN',
		'unit.check.ExtractRepeatedExpressionTest#testAFieldWriteBetweenOccurrencesSplitsTheGroup :: control :: '
			+ 'M-WRITE-SITES-SELF-FIELD,M-WRITE-SITES-MEMBER-TARGET,M-WRITE-SITES-INDEX-TARGET,M-WRITE-SITES-CAST-TARGET',
		'unit.check.ExtractRepeatedExpressionTest#testALiteralInteriorDifferenceSplitsTheGroup :: control :: '
			+ 'M-EXTRACT-REPEAT-RENDER-SPLIT',
		'unit.check.ExtractRepeatedExpressionTest#testAWriteBelowAChainKeepsItsReference :: control :: M-EXTRACT-REPEAT-REFERENCE-READ',
		'unit.check.ExtractRepeatedExpressionTest#testAWriteCarriedRoundALoopSplitsTheGroup :: control :: M-EXTRACT-REPEAT-BACK-EDGE',
		'unit.check.ExtractRepeatedExpressionTest#testAWriteInAClosureKillsTheGroup :: control :: M-EXTRACT-REPEAT-CLOSURE-WRITE',
		'unit.check.ExtractRepeatedExpressionTest#testAWriteInAMacroReificationIsNoWrite :: control :: M-WRITE-SITES-MACRO-EMIT',
		'unit.check.ExtractRepeatedExpressionTest#testAWriteOfAnUnnamedTargetSplitsTheGroup :: control :: M-EXTRACT-REPEAT-UNKNOWN-WRITE',
		'unit.check.ExtractRepeatedExpressionTest#testAWriteTargetIsNoOccurrence :: control :: M-EXTRACT-REPEAT-TARGET-COUNTED',
		'unit.check.ExtractRepeatedExpressionTest#testAnAssignmentBetweenOccurrencesSplitsTheGroup :: control :: '
			+ 'M-EXTRACT-REPEAT-WRITE-EFFECT,M-WRITE-SITES-PAREN-TARGET',
		'unit.check.ExtractRepeatedExpressionTest#testAnIncrementBetweenOccurrencesSplitsTheGroup :: control :: '
			+ 'M-EXTRACT-REPEAT-WRITE-SPLIT',
		'unit.check.ExtractRepeatedExpressionTest#testEffectFreeButNotTransparentCallExcluded :: control :: '
			+ 'M-STD-EFFECT-FREE-AS-TRANSPARENT',
		'unit.check.ExtractRepeatedExpressionTest#testOperandsBoundToDifferentDeclarationsAreSeparateGroups :: control :: '
			+ 'M-EXTRACT-REPEAT-REBIND',
		'unit.check.ExtractRepeatedExpressionTest#testProjectShadowOfAStdTypeExcluded :: control :: M-STD-SHADOW-IGNORED',
		'unit.check.ExtractRepeatedExpressionTest#testStringMethodAndPathStaticAreTransparent :: control :: '
			+ 'M-STD-SPLIT-TRANSPARENT,M-PURE-STRING-METHOD-OFF',
		'unit.check.FactsFixGateE2ETest#testAComputedClassNameTheProjectBoundsLetsTheLoopRewrite :: control :: '
			+ 'M-REFLECTIVE-BUILDS,M-REFLECTIVE-REACH,M-REFLECTIVE-WARN,M-ESCAPES-FACTS-UNMATCHED',
		'unit.check.FactsFixGateE2ETest#testAComputedMemberNameTheProjectBoundsLetsTheLoopRewrite :: control :: '
			+ 'M-HOLDERS-BUILDS,M-HOLDERS-REACH,M-HOLDERS-WARN,M-HOLDERS-READ',
		'unit.check.FactsFixGateE2ETest#testAMapHandedToMethodsThatKeepNothingLosesItsKeyUnderTheTruth :: control :: '
			+ 'M-FACTS-ARGUMENT-USE,M-FACTS-ARGUMENT-CAST,M-FACTS-ABSTRACT-WRAPPED-CAST,M-FACTS-IDENTITY-CAST-VALUE,M-TOUCH-ARGUMENT-USES,'
			+ 'M-GRAPH-MAP-USER-CODE',
		'unit.check.FactsFixGateE2ETest#testAMapTheLoopLeavesUnchangedLosesItsKeyFromItsSyntax :: control :: M-TOUCH-MAP-METHODS-UNKNOWN',
		'unit.check.FactsFixGateE2ETest#testAMapTheLoopLeavesUnchangedLosesItsKeyUnderTheTruth :: control :: '
			+ 'M-TOUCH-MAP-METHODS-UNKNOWN,M-REACH-LOCAL-MAP-ALIAS-PROVEN',
		'unit.check.FactsFixGateE2ETest#testANegationOnlyTheFactsTypeIsInverted :: control :: M-FOLD-FACTS-OPERAND',
		'unit.check.FactsFixGateE2ETest#testAPrivateMemberNoSupertypeDeclaresIsDeleted :: control :: '
			+ 'M-UNUSED-PRIVATE-CHAIN-FACTS,M-UNUSED-PRIVATE-CHAIN-DECLARED,M-UNUSED-PRIVATE-CHAIN-AUTOBUILD',

		'unit.check.FactsFixGateE2ETest#testAReceiverTheFactsTypeAsANonExternClassLosesItsToString :: control :: '
			+ 'M-TOSTRING-FACTS-CLASS,M-TOSTRING-FACTS-EXTERN,M-FACTS-ESCAPE-SHIFT',
		'unit.check.FactsFixGateE2ETest#testAStaticImportedUnderAnotherNameKeepsTheLoopWithoutTheTruth :: control :: '
			+ 'M-REACH-IMPORT-ALIAS,M-REACH-IMPORT-ALIAS-WORDS',
		'unit.check.FactsFixGateE2ETest#testAValueStoredInALocalOnlyIteratedLetsTheLoopRewrite :: control :: '
			+ 'M-FACTS-ASSIGN-HELD,M-TOUCH-TYPED-HELD-REGION',
		'unit.check.FactsFixGateE2ETest#testAnAbstractTheFactsTypeIsNeverJudgedByAnotherDeclarationOfItsName :: control :: '
			+ 'M-FOLD-FACTS-PLAIN-KINDS',
		'unit.check.FactsFixGateE2ETest#testAnOperandTheFactsTypeLetsTheMergeThrough :: control :: '
			+ 'M-FOLD-FACTS-OPERAND,M-FACTS-VALUE-TYPE-FLOWS',
		'unit.check.FactsFixGateE2ETest#testWhatTheConfigurationsRecordDifferentlyKeepsEveryFixOff :: control :: '
			+ 'M-FACTS-ALIKE-FOLD,M-FACTS-ALIKE-TOSTRING,M-FACTS-META-UNION',
		'unit.check.FactsTypeOracleE2ETest#testAReorderedFileIsPlacedOnlyThroughTheEditsItsRunApplied :: guard :: ',
		'unit.check.FactsTypeOracleE2ETest#testTheFactsTypeEveryDeclarationKindAndKeepTheProgram :: control :: M-ASSISTED-FACTS-FIRST,'
			+ 'M-ASSISTED-DECLINE-CENSUS,M-EXPLICIT-TYPE-ORACLE-PARAMS,M-EXPLICIT-TYPE-ORACLE-FIELDS,M-FACTS-DYNAMIC-SOURCE',
		'unit.check.FactsTypeOracleE2ETest#testTheFirstWriteWaitsForTheFactsCompile :: guard :: ',
		'unit.check.FactsTypeOracleTest#testAFieldTheConfigurationsTypeApartDeclines :: control :: M-FACTS-FIELD-TYPES',
		'unit.check.FactsTypeOracleTest#testAFinalClassIsItsOwnHome :: control :: M-ORACLE-HOME-MODIFIED-TYPE',
		'unit.check.FactsTypeOracleTest#testARangeHoldingCodeTheTextDoesNotSpellHasNoType :: control :: M-FACTS-READ-RECORD-NAME,M-FACTS-READ-NAME,M-FACTS-RECEIVER-CALL,M-FACTS-SPELLED-CALL,M-FACTS-FOREIGN-SITE,M-FACTS-TEMP-LOCAL,M-FACTS-TEMP-ALONE,M-FACTS-VALUE-CALLEE,M-FACTTEXT-EMPTY-MENTION,M-FACTTEXT-EMPTY-CALL',
		'unit.check.FactsTypeOracleTest#testARewriteDropsOnlyTheNodesThatReadIt :: control :: M-FACTS-MADE-FROM-ALL,M-FACTS-MADE-FROM-NONE',
		'unit.check.FactsTypeOracleTest#testARewrittenFileIsReadAtTheTextTheCompileRead :: control :: '
			+ 'M-FACTS-ORACLE-ORIGINAL,M-JOURNAL-SHIFT',
		'unit.check.FactsTypeOracleTest#testASignatureTheConfigurationsTypeApartDeclines :: control :: M-FACTS-SIGNATURE-VARIANTS',
		'unit.check.FactsTypeOracleTest#testASiteAfterNonAsciiTextIsFound :: control :: M-CODEPOINT-NATIVE',
		'unit.check.FactsTypeOracleTest#testATypeParameterOutOfScopeDeclines :: control :: M-FACTS-SPELL-SCOPE',
		'unit.check.FactsTypeOracleTest#testAValueIsTypedByTheFlowsAtItsRange :: control :: M-FACTS-VALUE-FLOWS,M-FACTS-ORACLE-RAW-AGREE',
		'unit.check.FactsTypeOracleTest#testAnEditAnywhereInTheMemberDeclines :: control :: M-ORACLE-WHOLE-MEMBER',
		'unit.check.FactsTypeOracleTest#testAnUnknownDeclines :: control :: M-FACTS-SPELL-UNKNOWN,M-FACTS-TREE-OPTIONAL',
		'unit.check.FactsTypeOracleTest#testCodeNoConfigurationCompiledDeclines :: control :: M-FACTS-ABSENT',
		'unit.check.FactsTypeOracleTest#testConfigurationsThatDisagreeDecline :: control :: M-FACTS-ORACLE-AGREE,M-FACTS-UNION',
		'unit.check.FactsTypeOracleTest#testExplicitTypeSaysWhyItsStructuralFixDeclined :: control :: M-EXPLICIT-TYPE-STRUCTURAL-DECLINE',
		'unit.check.FactsTypeOracleTest#testFactsOfAnotherMemberDecline :: control :: M-ORACLE-HOME-GUARD',
		'unit.check.FactsTypeOracleTest#testFactsOfAnotherTextThanTheOriginalAreStale :: control :: M-FACTS-INVALIDATE-FOREIGN',
		'unit.check.FactsTypeOracleTest#testTypesNoSourceCanSpellDecline :: control :: M-FACTS-SPELL-IMPL',
		'unit.check.FactsTypeTextTest#testOnlyAWrapperEnclosingTheWholeTypeIsPeeled :: control :: M-FACTS-NULL-PEEL-UNMATCHED',
		'unit.check.FieldInitAcrossSuperE2ETest#testAProvenInitCrossesSuperAndThePrefix :: control :: '
			+ 'M-FIAD-PROVEN-NEVER,M-FRESH-ONLY-ENTRY-FACETED',
		'unit.check.FieldInitAcrossSuperE2ETest#testAnObservableCrossingKeepsTheInit :: control :: '
			+ 'M-FIAD-PROVEN-ALWAYS,M-FIAD-PROVEN-NO-READER,M-FIAD-PROVEN-NO-COMMUTE,M-FIAD-PROVEN-EXPOSED,M-FRESH-ONLY-WRITES-ADMITTED,'
			+ 'M-FRESH-ONLY-STATEFUL-LIBRARY',
		'unit.check.FieldInitAcrossSuperE2ETest#testWithoutTheTruthTheInitStays :: control :: M-FIAD-PROVEN-ALWAYS',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testCollectionOfForeignReadAfterSuperNotMoved :: control :: '
			+ 'M-FIAD-INERT-ADMITS-ALL,M-FIAD-INERT-ELEMENT-ADMITS-ALL',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testCrossingWithoutResolutionRootsNotMoved :: control :: '
			+ 'M-FIAD-NO-ROOTS-ADMITTED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testEarlyReadComparedToNullRefused :: control :: M-FIAD-EARLY-READ-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testEarlyReadDefaultedRefused :: control :: M-FIAD-EARLY-READ-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testEarlyReadPassedAsArgumentRefused :: control :: '
			+ 'M-FIAD-EARLY-READ-IGNORED,M-FIAD-EARLY-READ-CALL-ARG',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testEarlyReadReturnedFromSubclassInOtherFileRefused :: control :: '
			+ 'M-FIAD-EARLY-READ-IGNORED,M-FIAD-EARLY-READ-SAME-FILE',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testEarlyReadSafeNavigatedRefused :: control :: M-FIAD-EARLY-READ-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testEarlyReadStoredRefused :: control :: M-FIAD-EARLY-READ-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testEarlyThisReadComparedToNullRefused :: control :: '
			+ 'M-FIAD-EARLY-READ-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testFaultingReadInLambdaOrLocalFunctionInsideTryRefused :: control :: '
			+ 'M-FIAD-TRY-BOUNDARY-CLEARED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testFaultingReadInsideTryRefused :: control :: M-FIAD-TRY-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testImportedUserMapShadowingTheCoreNameNotMoved :: control :: '
			+ 'M-FIAD-SHADOW-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testInertInitAfterSuperMovedWhenEveryReadFaults :: control :: '
			+ 'M-FIAD-CROSS-SUPER-UNPROVED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testNewInitAfterSuperNotMoved :: control :: M-FIAD-INERT-ADMITS-ALL',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testNonCoreDeclaredTypeNotMoved :: control :: M-FIAD-ANY-DECLARED-TYPE',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testPublicFieldNotMoved :: control :: '
			+ 'M-FIAD-PUBLIC-ADMITTED,M-EXPOSED-WRAPPER-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testRefusedCrossingInitDoesNotHoldBackTheFix :: control :: '
			+ 'M-FIAD-CROSS-SUPER-CHAIN',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testSameNamedFieldOfAnotherTypeDoesNotBlock :: control :: M-FIAD-DENOTES-ALL',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testSamePackageSiblingShadowingTheCoreNameNotMoved :: control :: '
			+ 'M-FIAD-SHADOW-IGNORED',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testScalarInitAfterSuperNotMoved :: control :: '
			+ 'M-FIAD-INERT-ADMITS-ALL,M-FIAD-CROSSING-ADMITS-SCALARS',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testSecondWriterAcrossSuperNotMoved :: control :: M-FIAD-CROSS-SUPER-NO-SOLE',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testStaticCallInitAfterSuperNotMoved :: control :: M-FIAD-INERT-ADMITS-ALL',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testStringInitAfterSuperNotMoved :: control :: '
			+ 'M-FIAD-INERT-ADMITS-ALL,M-FIAD-CROSSING-ADMITS-SCALARS',
		'unit.check.FieldInitAtDeclarationCrossingSuperTest#testThisReadOfAnotherTypeInSameFileDoesNotBlock :: control :: '
			+ 'M-FIAD-DENOTES-ALL',
		'unit.check.FieldInitInConstructorCheckTest#testConstantLandsInTheConstantsRank :: control :: M-LACKSMEMBER-FALSE',
		'unit.check.FieldWriteResolutionScopeTest#testLibraryStructureVetoesOnceStructuralJoins :: control :: M-CHECKINDEX-PROJECT-FINAL',
		'unit.check.FieldWriteResolutionScopeTest#testOutOfScopePlainClassKeepsTheUnresolvedWritePoison :: control :: '
			+ 'M-PLAINCLASS-SCOPEBLIND',
		'unit.check.FieldWriteResolutionScopeTest#testProjectRootUnresolvedWriteVetoes :: control :: M-ROOTS-THIRDPARTY',
		'unit.check.FieldWriteResolutionScopeTest#testResolvableLibraryInterfaceStopsVetoing :: control :: M-CHECKINDEX-PROJECT-FINAL',
		'unit.check.FieldWriteResolutionScopeTest#testResolvableLibraryInterfaceStopsVetoingWriteRestriction :: control :: '
			+ 'M-CHECKINDEX-PROJECT-READONLY',
		'unit.check.FieldWriteResolutionScopeTest#testSameSimpleNameThirdPartyTypeDoesNotVeto :: control :: M-DECLSITE-SCOPEWIDE',
		'unit.check.FieldWriteResolutionScopeTest#testSkipParsingLibrarySourceDoesNotVetoProjectCandidate :: control :: '
			+ 'M-SKIPSCAN-SCOPEWIDE',
		'unit.check.FieldWriteResolutionScopeTest#testThirdPartySubtypeWriteVetoesFinal :: control :: M-WRITEINDEX-PROJECT-FINAL',
		'unit.check.FieldWriteResolutionScopeTest#testThirdPartySubtypeWriteVetoesReadOnly :: control :: M-WRITEINDEX-PROJECT-READONLY',
		'unit.check.FieldWriteResolutionScopeTest#testThirdPartyUnresolvedWriteDoesNotVeto :: control :: M-ADMITS-TRUE',
		'unit.check.FixVerifierProbeRefusalE2ETest#testAWriterRefusedSetKeepsItsWritableUnits :: control :: M-WRITER-NARROW-NONE',
		'unit.check.FoldStringLiteralsCandidateGateTest#testEveryOutOfScopeCallSpellingIsRefused :: control :: M-MACRO-VALUE-UNLISTED',
		'unit.check.FoldStringLiteralsCheckTest#testConstantOperandMergesAsText :: control :: M-FOLD-CONSTANT-AS-EXPRESSION',
		'unit.check.FoldStringLiteralsWidthCheckTest#testStatementStandsInOnlyWhereItRendersAlike :: control :: M-FOLD-STATEMENT-UNPROVEN',
		'unit.check.GuardContinueCheckTest#testDefersADoWhileLoopGuardLifts :: control :: M-GUARD-CONTINUE-DEFERS-STATEMENT-BLOCK-ONLY',
		'unit.check.GuardContinueCheckTest#testElseBranchNotFlagged :: control :: M-GUARD-ELSE-ADMITTED',
		'unit.check.GuardContinueCheckTest#testEmptyBodyNotFlagged :: control :: M-GUARD-MIN-THEN-IGNORED',
		'unit.check.GuardContinueCheckTest#testGlueCommentNotFlagged :: control :: M-GUARD-GLUE-COMMENT-BLIND',
		'unit.check.GuardContinueCheckTest#testLessThanNotFlagged :: control :: M-GUARD-UNCLEAN-INVERSION-REPORTED',
		'unit.check.GuardContinueCheckTest#testUnbracedThenNotFlagged :: control :: M-GUARD-UNBRACED-THEN',
		'unit.check.GuardReturnCheckTest#testElseBranchNotFlagged :: control :: M-GUARD-ELSE-ADMITTED',
		'unit.check.GuardReturnCheckTest#testGlueCommentNotFlagged :: control :: M-GUARD-GLUE-COMMENT-BLIND',
		'unit.check.GuardReturnCheckTest#testSingleStatementThenNotFlagged :: control :: M-GUARD-MIN-THEN-IGNORED',
		'unit.check.GuardReturnCheckTest#testUnbracedCompoundThenNotFlagged :: control :: M-GUARD-UNBRACED-THEN',
		'unit.check.GuardReturnCheckTest#testUnprovableOrderedNotFlagged :: control :: M-GUARD-UNCLEAN-INVERSION-REPORTED',
		'unit.check.HaxeSpawnTest#testACancelledShellJobTakesItsChildrenWithIt :: control :: M-DRIVER-KILLS-ONLY-THE-SHELL',
		'unit.check.HaxeSpawnTest#testAFailureEndsTheJobsDeclaredAfterIt :: control :: M-DRIVER-NEVER-STOPS',
		'unit.check.HaxeSpawnTest#testAJobPastItsTimeoutIsKilled :: control :: M-DRIVER-NO-TIMEOUT',
		'unit.check.HaxeSpawnTest#testAKilledParentTakesItsJobsWithIt :: control :: M-DRIVER-OUTLIVES-ITS-PARENT',
		'unit.check.HaxeSpawnTest#testASignalledDriverTakesItsJobsWithIt :: control :: M-DRIVER-SIGNAL-ORPHANS',
		'unit.check.HaxeSpawnTest#testAWedgedDriverIsKilledAtItsBound :: control :: M-DRIVER-UNBOUNDED',
		'unit.check.HaxeSpawnTest#testTheDriverBoundScalesWithTheJobs :: control :: M-DRIVER-BOUND-IGNORES-ROUNDS',
		'unit.check.HaxeSpawnTest#testTheDriverReadsItsJobsFromNoPipe :: control :: M-DRIVER-READS-STDIN',
		'unit.check.HoistCommonImportTest#testANamesakePushesTheStatementToADeeperSite :: guard :: ',
		'unit.check.HoistCommonImportTest#testANestedSiteTakesOnlyWhatItsParentDidNot :: control :: '
			+ 'M-HOIST-SITE-ORDER,M-HOIST-CHAIN-INHERITED',
		'unit.check.HoistCommonImportTest#testASecondRunHasNothingToDo :: guard :: ',
		'unit.check.HoistCommonImportTest#testASubTypeImportIgnoresItsSiblings :: control :: M-HOIST-NEVER-SOUND',
		'unit.check.HoistCommonImportTest#testCreatesTheAmbientSourceAsAWholeFile :: guard :: ',
		'unit.check.HoistCommonImportTest#testDoesNotProposeWhatTheChainAlreadyProvides :: guard :: ',
		'unit.check.HoistCommonImportTest#testExtendingAnExistingSourceIsAnEdit :: guard :: ',
		'unit.check.HoistCommonImportTest#testExtendsAnExistingAmbientSource :: control :: M-HOIST-NEVER-SOUND',
		'unit.check.HoistCommonImportTest#testHoistedUsingsKeepTheirSourceOrder :: control :: M-HOIST-USINGS-SOURCE-ORDER',
		'unit.check.HoistCommonImportTest#testHoistsAnAllowListedUsing :: control :: M-HOIST-NEVER-SOUND',
		'unit.check.HoistCommonImportTest#testHoistsAnImportMostModulesSpell :: control :: M-HOIST-NEVER-SOUND',
		'unit.check.HoistCommonImportTest#testKeepsAnAllowListedUsingWhereARivalRemains :: control :: M-HOIST-USING-DEMOTION',
		'unit.check.HoistCommonImportTest#testOneSlicePerSite :: guard :: ',
		'unit.check.HoistCommonImportTest#testRefusesAGuardedStatement :: guard :: ',
		'unit.check.HoistCommonImportTest#testRefusesAModuleImportWhoseSiblingHasANamesake :: control :: M-IMPORT-LEAF-ONLY-NAMES',
		'unit.check.HoistCommonImportTest#testRefusesANamesakeReachedByAWildcard :: control :: M-HOIST-RETARGET-BAND',
		'unit.check.HoistCommonImportTest#testRefusesAPackageWildcard :: guard :: ',
		'unit.check.HoistCommonImportTest#testRefusesARootPackageNamesake :: control :: M-HOIST-RETARGET-BAND',
		'unit.check.HoistCommonImportTest#testRefusesASamePackageNamesake :: control :: M-HOIST-RETARGET-BAND',
		'unit.check.HoistCommonImportTest#testRefusesAStatementBindingAConstructor :: control :: M-HOIST-VALUES-BLIND',
		'unit.check.HoistCommonImportTest#testRefusesAStaticWildcard :: guard :: ',
		'unit.check.HoistCommonImportTest#testRefusesAUsingOffTheAllowList :: guard :: ',
		'unit.check.HoistCommonImportTest#testRefusesAnAlias :: guard :: ',
		'unit.check.HoistCommonImportTest#testWithholdsBelowTheMinimumModuleCount :: control :: M-HOIST-MIN-MODULES',
		'unit.check.HoistCommonImportTest#testWithholdsOnAnUnboundedChain :: control :: M-HOIST-SHORT-CHAIN',
		'unit.check.HoistCommonImportTest#testWithholdsWhereTheChainCarriesAGuardedStatement :: control :: M-HOIST-GUARDED-BLIND',
		'unit.check.ImportBlockOrderCheckTest#testAConstructorAndAModuleLevelFieldOfOneNameNeverBlock :: control :: M-BIND-RANKS-MERGED',
		'unit.check.ImportBlockOrderCheckTest#testAFieldImportOfAModuleLevelFieldIsListed :: control :: M-BIND-FIELD-IMPORT-MODULE-FIELD',
		'unit.check.ImportBlockOrderCheckTest#testAFieldWildcardSharingAStaticWithAFieldImportStaysABoundary :: control :: '
			+ 'M-BIND-FIELD-RANK-IGNORED,M-WILDGATE-FIELD-IMPORT-NO-NAME',
		'unit.check.ImportBlockOrderCheckTest#testAFieldWildcardWithFreeNamesJoinsTheBlock :: control :: '
			+ 'M-WILDGATE-NEVER-JOINS,M-RUN-GATE-NO-INDEX,M-FIX-GATE-NO-INDEX',
		'unit.check.ImportBlockOrderCheckTest#testAModuleLevelFieldOfAnExplicitImportBlocksAFieldWildcard :: control :: '
			+ 'M-BIND-FIELD-RANK-IGNORED,M-WILDGATE-MODULE-FIELDS-NONE',
		'unit.check.ImportBlockOrderCheckTest#testAPackageWildcardJoinsTheBlock :: control :: M-WILDGATE-NEVER-JOINS',
		'unit.check.ImportBlockOrderCheckTest#testAPrivateEnumConstructorIsNotBound :: control :: M-BIND-PRIVATE-TYPE-VALUES',
		'unit.check.ImportBlockOrderCheckTest#testAReorderedWildcardBlockRunsTheSame :: control :: '
			+ 'M-WILDGATE-NEVER-JOINS,M-BIND-FIELD-RANK-IGNORED',
		'unit.check.ImportBlockOrderCheckTest#testATypedefBindsTheConstructorsOfWhatItAliases :: control :: '
			+ 'M-BIND-TYPEDEF-NOT-FOLLOWED,M-BIND-NULL-WRAPPER-FOLLOWED',
		'unit.check.ImportBlockOrderCheckTest#testAUsingBindsNoModuleLevelField :: control :: M-BIND-USING-FIELDS',
		'unit.check.ImportBlockOrderCheckTest#testAWildcardBelowAWedgedUsingStaysBelowIt :: control :: M-WEDGE-WILDCARD-LIFTED',
		'unit.check.ImportBlockOrderCheckTest#testAWildcardBetweenTwoWedgedUsingsRefusesTheMerge :: control :: '
			+ 'M-WEDGE-WILDCARD-CROSSES-USING',
		'unit.check.ImportBlockOrderCheckTest#testAWildcardOfABuiltTypeStaysABoundary :: control :: M-WILDGATE-BUILD-READ',
		'unit.check.ImportBlockOrderCheckTest#testAWildcardOfASubclassStaysABoundary :: control :: M-WILDGATE-SUPERTYPE-READ',
		'unit.check.ImportBlockOrderCheckTest#testAWildcardOfATypedefStaysABoundary :: control :: M-WILDGATE-TYPEDEF-READ',
		'unit.check.ImportBlockOrderCheckTest#testAWildcardOfAnUnindexedTypeStaysABoundary :: control :: M-WILDGATE-UNKNOWN-TYPE-JOINS',
		'unit.check.ImportBlockOrderCheckTest#testAnEnumAbstractStaticIsNotAValueItsImportBinds :: control :: M-BIND-ABSTRACT-STATICS',
		'unit.check.ImportBlockOrderCheckTest#testAnEnumCarryingABuildMacroIsUnlisted :: control :: M-BIND-ENUM-BUILD-LISTED',
		'unit.check.ImportBlockOrderCheckTest#testAnEnumConstructorIsANameTheWildcardBinds :: control :: M-WILDGATE-ENUM-STATICS-ONLY',
		'unit.check.ImportBlockOrderCheckTest#testAnInstanceMemberIsNoNameTheWildcardBinds :: control :: M-WILDGATE-INSTANCE-BOUND',
		'unit.check.ImportBlockOrderCheckTest#testAnUnindexedExplicitImportNeverBlocksAPackageWildcard :: control :: '
			+ 'M-WILDGATE-PACKAGE-ASKS-EXPLICIT',
		'unit.check.ImportBlockOrderCheckTest#testAnUnindexedExplicitMemberKeepsAFieldWildcardABoundary :: control :: '
			+ 'M-WILDGATE-EXPLICIT-UNKNOWN-FREE',
		'unit.check.ImportBlockOrderCheckTest#testAnUnindexedModuleRefusesBesideAModuleLevelField :: control :: M-BIND-UNLISTED-FREE-LEFT',
		'unit.check.ImportBlockOrderCheckTest#testTheInsertSeatSortsAroundAMemberWildcard :: control :: M-SEAT-WILDCARD-BLIND',
		'unit.check.ImportBlockOrderCheckTest#testTwoFieldWildcardsSharingAStaticStayBoundaries :: control :: M-BIND-FIELD-RANK-IGNORED',
		'unit.check.ImportBlockOrderCheckTest#testTwoModulesBindingOneModuleLevelFieldKeepTheirOrderWhenRun :: control :: '
			+ 'M-BIND-FIELD-RANK-IGNORED,M-WILDGATE-MODULE-FIELDS-NONE',
		'unit.check.ImportBlockOrderCheckTest#testTwoModulesDeclaringOneModuleLevelFieldAreNotReordered :: control :: '
			+ 'M-BIND-FIELD-RANK-IGNORED,M-WILDGATE-MODULE-FIELDS-NONE',
		'unit.check.ImportBlockOrderCheckTest#testTwoPackageWildcardsSharingAModuleNameStayBoundaries :: control :: '
			+ 'M-WILDGATE-PACKAGE-NAMES-IGNORED',
		'unit.check.ImportBlockOrderCheckTest#testTwoTypeImportsSharingAConstructorAreNotReordered :: control :: '
			+ 'M-BIND-TYPE-VALUE-RANK-IGNORED,M-BIND-TYPE-VALUES-NONE',
		'unit.check.ImportBlockOrderCheckTest#testWildcardSplitsTheBlock :: control :: M-WILDGATE-UNKNOWN-TYPE-JOINS',
		'unit.check.ImportOutsideGuardCheckTest#testAMoveThatRebindsAConstructorIsRefused :: control :: M-GUARD-REBIND-BLIND',
		'unit.check.ImpossibleCastTest#testUnrelatedClassesFlagged :: control :: M-UNRELATED-FALSE',
		'unit.check.ImpossibleIsCheckTest#testUnrelatedClassesFlagged :: control :: M-UNRELATED-FALSE',
		'unit.check.InvertNegatedIfElseCheckTest#testDefaultLastImpliesKeepDefaultElse :: control :: M-NEGCOND-DEFAULT-LAST-NO-KEEP',
		'unit.check.InvertNegatedIfElseCheckTest#testDefaultLastIsOffByDefault :: control :: M-NEGCOND-DEFAULT-LAST-ON',
		'unit.check.InvertNegatedIfElseCheckTest#testDefaultLastLeavesWhatItCannotTurn :: control :: '
			+ 'M-NEGCOND-DEFAULT-LAST-BOTH-LITERALS,M-NEGCOND-DEFAULT-LAST-THEN-ANY,M-NEGCOND-DEFAULT-LAST-ANY-COND,'
			+ 'M-NEGCOND-DEFAULT-LAST-BOOL-COND,M-NEGCOND-DEFAULT-LAST-RETURN-MISMATCH',
		'unit.check.InvertNegatedIfElseCheckTest#testDefaultLastMessages :: control :: '
			+ 'M-INVERT-DEFAULT-LAST-VALUE-MESSAGE,M-INVERT-DEFAULT-LAST-STATEMENT-MESSAGE',
		'unit.check.InvertNegatedIfElseCheckTest#testDefaultLastTurnsADefaultFirstChoice :: control :: '
			+ 'M-NEGCOND-SWAP-DEFAULT-LAST-DROPPED,M-NEGCOND-SWAP-DEFAULT-LAST-ARMS-SWAPPED,'
			+ 'M-NEGCOND-DEFAULT-LAST-INTERPOLATION-AS-LITERAL',
		'unit.check.InvertNegatedIfElseCheckTest#testIfExpressionElseIfChainNotFlagged :: control :: M-INVERT-VALUE-CHAIN-SWAPPED',
		'unit.check.InvertNegatedIfElseCheckTest#testKeepDefaultElseInvertsANonDefaultElse :: control :: '
			+ 'M-NEGCOND-KEEP-DEFAULT-ANY-LITERAL,M-INVERT-KEEP-DEFAULT-STATEMENT-THEN-ARM,M-INVERT-KEEP-DEFAULT-VALUE-THEN-ARM',
		'unit.check.InvertNegatedIfElseCheckTest#testKeepDefaultElseIsOffByDefault :: control :: M-NEGCOND-KEEP-DEFAULT-ON',
		'unit.check.InvertNegatedIfElseCheckTest#testKeepDefaultElseKeepsADefaultIfExpressionElse :: control :: '
			+ 'M-NEGCOND-KEEP-DEFAULT-BLIND',
		'unit.check.InvertNegatedIfElseCheckTest#testKeepDefaultElseKeepsADefaultTernaryElse :: control :: '
			+ 'M-NEGCOND-KEEP-DEFAULT-BLIND,M-NEGCOND-KEEP-DEFAULT-NO-PAREN,M-DEFLIT-NULL-DROPPED,M-DEFLIT-FALSE-DROPPED,'
			+ 'M-DEFLIT-ZERO-DROPPED,M-DEFLIT-EMPTY-STRING-DROPPED',
		'unit.check.InvertNegatedIfElseCheckTest#testKeepDefaultElseKeepsAStatementReturningADefault :: control :: '
			+ 'M-NEGCOND-KEEP-DEFAULT-NO-RETURN,M-NEGCOND-KEEP-DEFAULT-NO-BLOCK',
		'unit.check.InvertNegatedIfElseCheckTest#testNegatedTernaryAssignmentOperandKeepsParen :: control :: M-INVERT-VALUE-UNGUARDED',
		'unit.check.InvertNegatedIfElseCheckTest#testNegatedTernaryFixed :: control :: M-INVERT-VALUE-LOOSE-SPAN',
		'unit.check.InvertNegatedIfElseCheckTest#testNegatedTernaryOperandParenDrops :: control :: M-NEGCOND-PAREN-KEPT',
		'unit.check.InvertNegatedIfElseCheckTest#testNestedNegatedTernaryOnePerPass :: control :: M-INVERT-VALUE-DESCEND-FIXED',
		'unit.check.InvertNegatedIfElseCheckTest#testReportOnlyTernaryDescended :: control :: M-INVERT-VALUE-NO-DESCEND',
		'unit.check.InvertNegatedIfElseCheckTest#testStatementCommentInsideOperandTravels :: control :: M-NEGCOND-COMMENT-WHOLE-COND',
		'unit.check.InvertNegatedIfElseCheckTest#testTernaryChainNotFlagged :: control :: M-INVERT-VALUE-CHAIN-SWAPPED',
		'unit.check.InvertNegatedIfElseCheckTest#testTernaryConditionCommentReportOnly :: control :: M-NEGCOND-COMMENT-BEFORE-KEPT',
		'unit.check.InvertNegatedIfElseCheckTest#testTernaryGlueCommentReportOnly :: control :: '
			+ 'M-INVERT-VALUE-GLUE-BEFORE-BLIND,M-INVERT-VALUE-GLUE-AFTER-BLIND',
		'unit.check.InvertNegatedIfElseCheckTest#testTernaryNonTopLevelNotNotFlagged :: control :: M-NEGCOND-ANY-KIND',
		'unit.check.InvertNegatedIfElseCheckTest#testTernaryParenCommentReportOnly :: control :: M-NEGCOND-COMMENT-AFTER-KEPT',
		'unit.check.JoinSingleUseLocalCheckTest#testAnnotationRestatesSourceFlagged :: control :: M-JSUL-ANNOTATION-NEVER-NEUTRAL',
		'unit.check.JoinSingleUseLocalCheckTest#testCommentBetweenStatementsStillFlagged :: control :: M-JSUL-COMMENT-ANY-IN-FILE',
		'unit.check.JoinSingleUseLocalCheckTest#testConditionalBareIdentStillFlagged :: control :: M-JSUL-BARE-IDENT-NOT-SAFE',
		'unit.check.JoinSingleUseLocalCheckTest#testConditionalRegionWithoutStrayReadStillFlagged :: control :: '
			+ 'M-JSUL-UNINDEXED-NAME-ALWAYS',
		'unit.check.JoinSingleUseLocalCheckTest#testImmutableLocalCaptureStillFlagged :: control :: M-JSUL-LOCAL-CAPTURE-ANY',
		'unit.check.JoinSingleUseLocalCheckTest#testInitIdentNotReboundStillFlagged :: control :: M-JSUL-INIT-IDENT-ALWAYS-REBOUND',
		'unit.check.JoinSingleUseLocalCheckTest#testTrailingStatementWithoutInterpolationStillFlagged :: control :: '
			+ 'M-JSUL-UNINDEXED-NAME-ALWAYS',
		'unit.check.JoinSingleUseLocalCheckTest#testUnconditionalFieldChainStillFlagged :: control :: M-JSUL-PATH-ALWAYS-CONDITIONAL',
		'unit.check.LintConfigInheritanceTest#testAnUnnamedKeyFallsThroughToTheAncestor :: control :: '
			+ 'M-REFLECTIVE-MERGE,M-HOLDERS-MERGE,M-OWNED-MERGE',
		'unit.check.LintConfigTest#testReachSkipsBranchesOnlyUnderADeclaredCompleteOracleList :: control :: M-REACH-CONFIGS-COMPLETE',
		'unit.check.LintConfigTest#testReachTakesTheBuildsAsCompleteOnlyWhenEveryPathAgrees :: control :: M-REACH-CONFIGS-AGREE',
		'unit.check.LintConfigTest#testTheCompileDirProbeReadsTheHxmlAsTheCompilerDoes :: control :: '
			+ 'M-HXML-QUOTES-KEPT,M-COMPILEDIR-PROBE-BLIND',
		'unit.check.LintConfigTest#testTheReflectiveClassesAreTheRunsOnlyWhenEveryPathDeclaresThemAlike :: control :: '
			+ 'M-REFLECTIVE-AGREE,M-HOLDERS-PARSE',
		'unit.check.LintFixDeclineWiringSliceTest#testACrossFileRuleIsNotReportedAsSayingNothing :: control :: M-LEDGER-CROSS-FILE-MUTE',
		'unit.check.LintFixDeclineWiringSliceTest#testAGuardRefusedFindingCostsItsRuleNothingElse :: control :: M-LINTFIX-GUARD-SPLIT-NONE',
		'unit.check.LintFixDeclineWiringSliceTest#testARefusedFindingCostsItsRuleNothingElse :: control :: M-LINTFIX-FINDING-SPLIT-NONE',
		'unit.check.LintFixDeclineWiringSliceTest#testARefusedRuleCostsOnlyItsOwnEdits :: control :: M-LINTFIX-BLAME-SITE-ALWAYS',
		'unit.check.LintFixDeclineWiringSliceTest#testARiskyArmRuleCountsEachFindingOnceWhenTheArmDeclines :: control :: '
			+ 'M-ARM-LEDGER-REPORTED-TWICE,M-ARM-LEDGER-HANDOFF-KEPT',
		'unit.check.LintFixDeclineWiringSliceTest#testARiskyArmRuleIsNeverListedAsAbsent :: control :: M-LEDGER-ARM-LISTED-ABSENT',
		'unit.check.LintFixDeclineWiringSliceTest#testARiskyArmRuleThatLandedDeclinesOnlyWhatItLeft :: control :: '
			+ 'M-ARM-LEDGER-REPORTED-TWICE,M-ARM-LEDGER-HANDOFF-KEPT',
		'unit.check.LintFixDeclineWiringSliceTest#testAnAcceptedFileIsWrittenAndBlamesNobody :: control :: M-LINTFIX-ACCEPTED-BLAMED',
		'unit.check.LintFixDeclineWiringSliceTest#testHandOffsStayDeclinedWithoutTheRiskyPhase :: control :: '
			+ 'M-ARM-LEDGER-HANDOFF-UNRECORDED,M-ARM-LEDGER-ARM-BLIND',
		'unit.check.LintFixSafeRevertContinuesTest#testANarrowedRevertKeepsTheGoodSafeEditAndTheVerifiedOnes :: control :: '
			+ 'M-SAFE-REVERT-ABORTS,M-SAFE-REVERT-EDITS-COUNTED,M-SAFE-REVERT-FILES-COUNTED,M-SAFE-REVERT-EXIT-OK',
		'unit.check.LintFixSafeRevertContinuesTest#testRiskyAndOracleAssistedFixesLandAfterAWholeWaveSafeRevert :: control :: '
			+ 'M-SAFE-REVERT-ABORTS,M-SAFE-REVERT-EDITS-COUNTED,M-SAFE-REVERT-FILES-COUNTED,M-SAFE-REVERT-EXIT-OK,M-SAFE-REVERT-UNSAID',
		'unit.check.LintLanguageVersionGateTest#testAnExplicitRuleSelectionKeepsTheVersionFloor :: control :: M-VERSION-LIFTED-BY-RULE',
		'unit.check.LintModuleSecondaryTypeSliceTest#testAModuleWhoseConstructorsCannotBeListedStaysAdvisory :: control :: '
			+ 'M-UNUSED-VALUES-UNLISTED-DELETED',
		'unit.check.LintModuleSecondaryTypeSliceTest#testModuleLevelFieldUseKeepsModuleImport :: control :: '
			+ 'M-UNUSED-VALUES-BLIND,M-WILDGATE-MODULE-FIELDS-NONE',
		'unit.check.LintModuleSecondaryTypeSliceTest#testTheLastBinderOfAModuleLevelFieldIsKept :: control :: M-UNUSED-VALUES-BLIND',
		'unit.check.LintReportChannelSliceTest#testASummaryIsPerRuleAndOneRuleIsByFile :: control :: M-LINT-SUMMARY-ONE-SHAPE',
		'unit.check.LintReportChannelSliceTest#testATextRunOverTheThresholdPrintsTheSummary :: control :: M-LINT-SUMMARY-THRESHOLD-UNREAD',
		'unit.check.LintReportChannelSliceTest#testTheThresholdDecidesBetweenListAndSummary :: control :: M-LINT-SUMMARY-NEVER',
		'unit.check.LintScopeGateTest#testALibsOnlyScopeIsNamedAsAGap :: control :: M-SCOPE-GAP-SILENT',
		'unit.check.LintSliceTest#testFixSkipsSideEffectingInit :: control :: M-UNUSED-LOCAL-IMPURE-UNSAID',
		'unit.check.LintSliceTest#testUnusedLocalFixSkipsMultiVarContinuation :: control :: M-UNUSED-LOCAL-SHARED-LINE-UNSAID',
		'unit.check.LoopBoundLengthMismatchCheckTest#testABinderTakingTheNameRefuses :: control :: M-LOOPBOUND-SHADOW',
		'unit.check.LoopBoundLengthMismatchCheckTest#testABoundNamingTheArrayIsRelated :: control :: M-LOOPBOUND-RELATED-OFF',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAComprehensionLiteralIsNoLength :: control :: M-LOOPBOUND-UNSIZED',
		'unit.check.LoopBoundLengthMismatchCheckTest#testADeclaredTypeOtherThanTheBuiltOneRefuses :: control :: M-LOOPBOUND-TYPE-OFF',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAFieldFilledInTheConstructorIsReportedAgainstAnUnrelatedBound :: control :: '
			+ 'M-LOOPBOUND-SILENT',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAFillLoopThatMayJumpRefuses :: control :: M-LOOPBOUND-EXITS',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAFixedLengthConstructionIsItsArgument :: control :: '
			+ 'M-LOOPBOUND-SILENT,M-LOOPBOUND-FIXED-WRITE',
		'unit.check.LoopBoundLengthMismatchCheckTest#testALiteralIsItsElementCount :: control :: M-LOOPBOUND-SILENT',
		'unit.check.LoopBoundLengthMismatchCheckTest#testALocalFilledByALoopIsReported :: control :: M-LOOPBOUND-SILENT',
		'unit.check.LoopBoundLengthMismatchCheckTest#testALoopInsideTheFillLoopIsNotChecked :: control :: M-LOOPBOUND-NESTED-FILL',
		'unit.check.LoopBoundLengthMismatchCheckTest#testALoopThatOnlyWritesIsNotReported :: control :: M-LOOPBOUND-WRITE-READ',
		'unit.check.LoopBoundLengthMismatchCheckTest#testANameAheadOfTheLocalRefuses :: control :: M-LOOPBOUND-AHEAD',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAPublicFieldIsNotConfined :: control :: M-LOOPBOUND-PUBLIC',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAReadPastTheIndexMovesTheReach :: control :: M-LOOPBOUND-REACH-IGNORED',
		'unit.check.LoopBoundLengthMismatchCheckTest#testASelfQualifiedReadIsAnOccurrence :: control :: M-LOOPBOUND-SELF-REF',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAStaticFieldFilledInTheConstructorRefuses :: control :: M-LOOPBOUND-STATIC-FILL',
		'unit.check.LoopBoundLengthMismatchCheckTest#testASubtypeMentioningTheFieldRefuses :: control :: M-LOOPBOUND-CONFINED-OFF',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAnAppendOutsideTheFillLoopRefuses :: control :: M-LOOPBOUND-ADMIT-ALL',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAnArrayHandedOutHasNoKnownLength :: control :: M-LOOPBOUND-ADMIT-ALL',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAnImportedSimpleNameIsTheFixedLengthType :: control :: M-LOOPBOUND-SILENT',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAnIndexWriteExtendsAnArray :: control :: M-LOOPBOUND-ARRAY-WRITE',
		'unit.check.LoopBoundLengthMismatchCheckTest#testAnUnimportedVectorIsNoFixedLengthType :: control :: M-LOOPBOUND-VECTOR-IMPORT',
		'unit.check.LoopBoundLengthMismatchCheckTest#testFoldedConstantsCompareByValue :: control :: M-LOOPBOUND-FOLD-OFF',
		'unit.check.LoopBoundLengthMismatchCheckTest#testParallelArraysShareTheirBound :: control :: M-LOOPBOUND-RELATED-OFF',
		'unit.check.LoopGuardCheckTest#testDoWhileLoopFlaggedAndFixed :: control :: '
			+ 'M-LOOPGUARD-DO-WHILE-BODY-LAST,M-LOOPGUARD-BODY-STATEMENT-BLOCK-ONLY',
		'unit.check.LoopGuardCheckTest#testDoWhileMergeArmJoinsTheHeader :: control :: '
			+ 'M-LOOPGUARD-EXPR-BODY-KEPT,M-LOOPGUARD-HEADER-STATEMENT-IF-ONLY,M-LOOPGUARD-BRANCH-STATEMENT-BLOCK-ONLY',
		'unit.check.MagicNumberCheckTest#testADirectArgumentOfAnIgnoredCallIsExempt :: control :: M-MAGIC-CALLARG-BLIND',
		'unit.check.MagicNumberCheckTest#testADottedEntryMatchesTheCalleeTail :: control :: M-MAGIC-CALLARG-SUFFIX-LOOSE',
		'unit.check.MagicNumberCheckTest#testANamedCollectionOfLiteralsIsATable :: control :: '
			+ 'M-MAGIC-TABLE-COLLECTION-BLIND,M-MAGIC-TABLE-COLLECTION-UNNAMED',
		'unit.check.MagicNumberCheckTest#testANegatedArgumentOfAnIgnoredCallIsExempt :: control :: M-MAGIC-CALLARG-NEG-BLIND',
		'unit.check.MagicNumberCheckTest#testASwitchOfLiteralArmsIsATable :: control :: '
			+ 'M-MAGIC-TABLE-SWITCH-BLIND,M-MAGIC-TABLE-SWITCH-ARM-LOOSE',
		'unit.check.MagicNumberCheckTest#testAValueObjectBuiltInAListedArgumentIsExempt :: control :: M-MAGIC-CALLARG-NESTED-NEW',
		'unit.check.MagicNumberCheckTest#testAnIgnoredConstructorIsSpelledDotNew :: control :: M-MAGIC-CALLARG-NEW-BLIND',
		'unit.check.MagicNumberCheckTest#testLiteralTablesAreOffByDefault :: control :: M-MAGIC-TABLES-DEFAULT-ON',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupBlankInConditionalRebuildUnderOption :: control :: '
			+ 'M-MO-INLINE-BOUNDARY-OFF,M-MO-INLINE-SEPARATOR-DROPPED,M-MO-INLINE-CONDITIONAL-REBUILD-UNREAD',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupBlankInsertedBySpacingOnlyFallback :: control :: '
			+ 'M-MO-INLINE-BOUNDARY-OFF,M-MO-INLINE-SPACING-ONLY-UNREAD',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupBlankInsertedUnderOption :: control :: '
			+ 'M-MO-INLINE-BOUNDARY-OFF,M-MO-INLINE-REPORT-UNREAD,M-MO-INLINE-FIX-UNREAD,M-MO-INLINE-MESSAGE-AS-RANK',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupBlankKeptUnderOption :: control :: '
			+ 'M-MO-INLINE-BOUNDARY-OFF,M-MO-INLINE-REPORT-UNREAD',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupBlankOnReorderUnderOption :: control :: '
			+ 'M-MO-INLINE-BOUNDARY-OFF,M-MO-INLINE-SEPARATOR-DROPPED',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupBlankRemovedByDefault :: control :: M-MO-INLINE-OPTION-IGNORED',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupDoubleBlankCollapsesUnderOption :: control :: '
			+ 'M-MO-INLINE-BOUNDARY-OFF,M-MO-INLINE-BOUNDARY-AT-LEAST-ONE',
		'unit.check.MemberOrderCheckTest#testInlineSubgroupOptionLeavesTheRestAlone :: control :: '
			+ 'M-MO-INLINE-CONDITIONAL-BOUNDARY,M-MO-INLINE-BOUNDARY-BEFORE-EXEMPTIONS',
		'unit.check.MemberOrderWriterGapTest#testADocCommentedFieldIsSetOffAsTheWriterSetsItOff :: control :: '
			+ 'M-MO-WRITER-DOC-IGNORED,M-MO-WRITER-FIX-UNREAD,M-MO-INLINE-SEPARATOR-DROPPED',
		'unit.check.MemberOrderWriterGapTest#testAGluedMultiLineFieldIsReportedAndTheFixLandsTheWritersBlank :: control :: '
			+ 'M-MO-WRITER-MULTILINE-IGNORED,M-MO-INLINE-SEPARATOR-DROPPED',
		'unit.check.MemberOrderWriterGapTest#testALineCommentLedSlotIsLeftToTheSource :: control :: M-GAP-DOCLED-ANY-COMMENT',
		'unit.check.MemberOrderWriterGapTest#testAMultiLineMemberStillGetsItsBlankUnderBeforeDocNone :: control :: '
			+ 'M-GAP-MULTILINE-AFTER-NOBLANK',
		'unit.check.MemberOrderWriterGapTest#testAnIfBodyKeepsItsSourceGaps :: control :: M-MO-WRITER-CONDITIONAL',
		'unit.check.MemberOrderWriterGapTest#testTheBeforeDocNonePolicyRemovesTheBlankAndWins :: control :: M-GAP-DOC-PRECEDENCE',
		'unit.check.MemberOrderWriterGapTest#testTheWritersBlankAroundAMultiLineFieldIsNotReported :: control :: '
			+ 'M-MO-WRITER-REPORT-UNREAD,M-MO-WRITER-MULTILINE-IGNORED',
		'unit.check.MemberOrderWriterGapTest#testTheWritersDocBlankIsAMinimum :: control :: M-MO-WRITER-MINIMUM-AS-EXACT',
		'unit.check.MemberSpacingPolicyTest#testAnUnmeasurableSlotLeavesThePairToTheSource :: control :: M-MO-WRITER-UNMEASURABLE-GUESS',
		'unit.check.MemberSpacingPolicyTest#testTheWriterPolicyIsReadOnlyOnTheKindsItCovers :: control :: M-MO-WRITER-CONTAINER-KIND',
		'unit.check.NamingCheckCrossFileFixTest#testAGrantedMemberRenamesIntoItsGranteesAndTheirSubtypes :: control :: '
			+ 'M-ALLOW-GRANTEE-SUBTYPES,M-NAMING-ALLOWGRANT-AS-ANNOTATION,M-NAMING-CROSS-GRANTEES-DROPPED',
		'unit.check.NamingCheckCrossFileFixTest#testAMemberGrantDoesNotTaintItsNeighbours :: control :: '
			+ 'M-ALLOW-REACHING-FILE,M-CONFINED-GRANTS-IGNORED',
		'unit.check.NamingCheckCrossFileFixTest#testANarrowedPublicRenameRefusesAReaderOutsideItsScope :: control :: '
			+ 'M-NAMING-OUTSIDE-SCOPE-IGNORED',
		'unit.check.NamingCheckCrossFileFixTest#testAPackageGrantRenamesIntoThePackage :: control :: M-ALLOW-GRANTEE-PACKAGE',
		'unit.check.NamingCheckCrossFileFixTest#testASubtypeParameterOfTheSameNameIsNotRenamed :: control :: '
			+ 'M-NAMING-FOREIGN-LOSES-TO-BARE',
		'unit.check.NamingCheckCrossFileFixTest#testAnUnrelatedSameNamedPrivateDoesNotBlockAPublicRename :: control :: '
			+ 'M-NAMING-FOREIGN-UNBOUND',
		'unit.check.NamingCheckCrossFileFixTest#testCrossFileRenameAsksTheResolutionScopeForUnreadableFiles :: control :: '
			+ 'M-NAMING-SKIPSCAN-REPORT-INDEX,M-SKIPSCAN-SCOPEWIDE',
		'unit.check.NamingCheckCrossFileFixTest#testUnresolvableHierarchyTellsItsTwoCausesApart :: control :: M-ALLOW-GRANTEE-UNMATCHED',
		'unit.check.NamingCheckLocalFixTest#testLocalAndParamCollisionsNameTheTakenName :: control :: M-NAMING-LOCAL-CROSS-NOTE',
		'unit.check.NamingCheckMemberFixTest#testAccessGrantOutsideReportScopeRefusesSingleFileRename :: control :: '
			+ 'M-CONFINEMENT-REPORT-INDEX-RENAME',
		'unit.check.NamingCheckMemberFixTest#testReflectionCallOutsideReportScopeRefusesRename :: control :: '
			+ 'M-REFLECTION-REPORT-INDEX-RENAME',
		'unit.check.NamingCheckTest#testAPublicStaticReadOnlyPropertyTakesTheConstantPolicy :: control :: '
			+ 'M-NAMING-PROPERTY-MODS-NONE,M-NAMING-READONLY-IGNORES-WRITE,M-NAMING-READONLY-RULE-INSTANCE,M-ACCESSOR-STORAGELESS-TRUE',
		'unit.check.NamingCheckTest#testAStoragelessPrivatePropertyIsExemptFromTheFieldPrefix :: control :: M-NAMING-PROPERTY-MODS-NONE,'
			+ 'M-NAMING-STORAGELESS-ISVAR,M-NAMING-STORAGELESS-REGION,M-ACCESSOR-STORAGELESS-TRUE,M-NAMING-STORAGELESS-RULE-PUBLIC',
		'unit.check.NamingCheckTest#testEnumAbstractPropertyAndStaticTakeTheMemberPolicy :: control :: '
			+ 'M-NAMING-ENUMVALUE-PROPERTY,M-NAMING-ENUMVALUE-STATIC,M-NAMING-PROPERTY-FACTS-NULL',
		'unit.check.NamingCrossRenameTest#testANamesakesSubtypesDoNotUnconfineAPrivate :: control :: M-CONFINED-NO-OWNER-FILE',
		'unit.check.NamingCrossRenameTest#testATypedefRenamesInEveryFileThatNamesIt :: control :: '
			+ 'M-XRENAME-NOT-CANDIDATE,M-XRENAME-FINDINGS-NONE,M-XRENAME-EDITS-DROPPED',
		'unit.check.NamingCrossRenameTest#testAnEnumAbstractAndItsValuesRename :: control :: M-XRENAME-INDEXED-UNDERLYING',
		'unit.check.NamingCrossRenameTest#testEachGateRefusesWithItsReason :: control :: '
			+ 'M-XRENAME-RUNTIME-TYPE,M-XRENAME-MAIN-TYPE,M-XRENAME-TYPE-META,M-XRENAME-GUARDED,M-XRENAME-ENUM-CTOR,M-XRENAME-STRING,'
			+ 'M-XRENAME-TYPE-PATH,M-XRENAME-OLD-SHARED,M-XRENAME-NEW-DECLARED,M-XRENAME-NEW-SPELLED,M-XRENAME-VALUE-OLD-SHARED,'
			+ 'M-XRENAME-VALUE-NEW-SHARED,M-XRENAME-VALUE-BOUND,M-XRENAME-OUTSIDE,M-XRENAME-VALUE-META',
		'unit.check.NamingCrossRenameTest#testInertNeighboursDoNotRefuse :: control :: '
			+ 'M-XRENAME-SAFE-META,M-XRENAME-VALUE-PROPERTY,M-XRENAME-STRING-TYPES-ONLY',
		'unit.check.NamingCrossRenameTest#testSetsSharingAFileFormOneComponent :: control :: M-XVERIFY-NO-MERGE',
		'unit.check.NamingCrossRenameTest#testTheArmNeedsTheWholeProject :: control :: M-XRENAME-NO-PROJECT',
		'unit.check.NamingCrossRenameTest#testTheOracleRunRenamesAndRevertsTheMiss :: control :: '
			+ 'M-RISKYARM-CROSS-NOT-VERIFIED,M-XVERIFY-NO-BISECT',
		'unit.check.NamingPrivatizeTest#testANameThePrivateRuleRejectsIsNotACandidate :: control :: M-PRIVATIZE-RULE-UNCHECKED',
		'unit.check.NamingPrivatizeTest#testANarrowedRunSeesAReaderOutsideItsScope :: control :: M-PRIVATIZE-TOKENS-UNCHECKED',
		'unit.check.NamingPrivatizeTest#testAPublicUnderscoreFieldReadOnlyInsideIsPrivatized :: control :: '
			+ 'M-PRIVATIZE-NO-CANDIDATE,M-NAMING-PRIVATIZE-NOT-DECLINED,M-NAMING-RISKYFIX-EMPTY',
		'unit.check.NamingPrivatizeTest#testASubtypeReaderStillPrivatizes :: control :: M-PRIVATIZE-NO-SUBTYPE-REGION',
		'unit.check.NamingPrivatizeTest#testAnAutoBuildAncestorDoesNotRefuse :: control :: M-PRIVATIZE-AUTOBUILD-COUNTS',
		'unit.check.NamingPrivatizeTest#testAnOutsideReaderKeepsTheRename :: control :: '
			+ 'M-NAMING-RISKY-FINDINGS-ALL,M-PRIVATIZE-TOKENS-UNCHECKED',
		'unit.check.NamingPrivatizeTest#testAnUnrelatedSameNamedPrivateDoesNotRefuse :: control :: '
			+ 'M-PRIVATIZE-FOREIGN-IGNORED,M-NAMING-FOREIGN-UNBOUND',
		'unit.check.NamingPrivatizeTest#testEachGateRefusesTheArm :: control :: M-PRIVATIZE-UNCERTAIN-RUN,'
			+ 'M-PRIVATIZE-TYPE-REACH,M-PRIVATIZE-CHAIN,M-PRIVATIZE-ACCESS-GRANT,M-PRIVATIZE-FRAGMENT,M-PRIVATIZE-TOKENS-UNCHECKED',
		'unit.check.NamingPrivatizeTest#testNoDeclaredScopeLeavesTheRename :: control :: M-PRIVATIZE-INCOMPLETE-PROJECT',
		'unit.check.NamingPrivatizeTest#testTheCandidateTestIsAPositiveList :: control :: M-PRIVATIZE-METHOD-CANDIDATE,'
			+ 'M-PRIVATIZE-NO-UNDERSCORE,M-PRIVATIZE-NOT-PUBLIC,M-PRIVATIZE-NO-OWNER,M-PRIVATIZE-IMPLICIT-REACH,M-PRIVATIZE-RENAME-UNSAFE',
		'unit.check.NamingPrivatizeTest#testTheOracleRunPrivatizes :: control :: M-RISKYARM-NOT-VERIFIED,M-FIXVERIFY-RISKYARM-FIX',
		'unit.check.NoUnderscorePrefixCheckTest#testNamingYieldsTheBindingThisRuleReports :: control :: '
			+ 'M-LINT-SUPERSEDES-IGNORED,M-NUP-SUPERSEDES-NONE',
		'unit.check.NoUnderscorePrefixCheckTest#testRefusedStripDeclaresItsReason :: control :: M-NUP-DECLINE-SILENT',
		'unit.check.NoUnderscorePrefixCheckTest#testTheFixerSeesTheBindingOnce :: control :: M-FIXDRIVER-SUPERSEDES-IGNORED',
		'unit.check.NullFlowReplayTest#testADeclaredNullableWalkIsNeverReplayed :: control :: M-NULLFLOW-MEMO-DECLARED-BLIND',
		'unit.check.NullFlowReplayTest#testARecordingIsKeptForItsOwnSourceOnly :: control :: M-NULLFLOW-MEMO-SOURCE-BLIND',
		'unit.check.NullFlowReplayTest#testAReplayAnswersWhatTheLiveWalkAnswered :: control :: M-NULLFLOW-FROZEN-STALE',
		'unit.check.NullFlowReplayTest#testASeededWalkIsNeverReplayed :: control :: M-NULLFLOW-MEMO-SEED-BLIND',
		'unit.check.NullFlowReplayTest#testATypeSourcesWalkIsNeverReplayed :: control :: M-NULLFLOW-MEMO-TYPES-BLIND',
		'unit.check.NullFlowReplayTest#testForgetDropsTheRecording :: control :: M-NULLFLOW-MEMO-NOT-FORGOTTEN',
		'unit.check.NullableSourceResolutionScopeTest#testExcludedArrayPopStaysUnseeded :: control :: M-NULLABLE-INDEX-EXCLUSION',
		'unit.check.NullableSourceResolutionScopeTest#testLibraryReturnBindingSeeded :: control :: M-NULLABLE-FLOW-REPORT-INDEX',
		'unit.check.NullableSourceResolutionScopeTest#testLibraryReturnDerefFlagged :: control :: M-NULLABLE-REPORT-INDEX',
		'unit.check.NullableSourceResolutionScopeTest#testLibraryStaticReturnDerefFlagged :: control :: M-NULLABLE-REPORT-INDEX',
		'unit.check.NullableSwitchMissingNullCheckTest#testDeclaredLocalFromAMapReadFlagged :: control :: M-NULLABLE-NO-CHAIN',
		'unit.check.OperandBindingTest#testAliasOfUnindexedTypeOutranksSamePackageClass :: control :: M-BINDING-ALIAS-BLIND',
		'unit.check.OperandBindingTest#testAmbientImportOfUnindexedTypeOutranksSamePackageClass :: control :: '
			+ 'M-BINDING-UNINDEXED-IMPORT-FREE',
		'unit.check.OperandBindingTest#testCallToFunctionOfThisFileIsProven :: control :: M-OPERAND-LOCAL-CALL-CUT',
		'unit.check.OperandBindingTest#testConstructionIsOfTheTypeItWrites :: control :: M-OPERAND-NEW-CUT',
		'unit.check.OperandBindingTest#testDeclarationInsideTheBranchOutranksItsCapture :: control :: M-OPERAND-CASE-CAPTURE-INSIDE',
		'unit.check.OperandBindingTest#testImportOfUnindexedTypeIsNotItsIndexedNamesake :: control :: M-OPERAND-SIMPLE-NAME',
		'unit.check.OperandBindingTest#testImportOfUnindexedTypeOutranksSamePackageClass :: control :: M-BINDING-UNINDEXED-IMPORT-FREE',
		'unit.check.OperandBindingTest#testJoinAppendBindsTheTarget :: control :: M-BINDING-UNINDEXED-IMPORT-FREE',
		'unit.check.OperandBindingTest#testLocalMacroIsNotTypedByItsReturn :: control :: M-OPERAND-LOCAL-MACRO',
		'unit.check.OperandBindingTest#testMacroMemberIsNotTypedByItsReturn :: control :: M-OPERAND-MACRO-RETURN',
		'unit.check.OperandBindingTest#testMemberOfBuiltinTypeIsProven :: control :: M-OPERAND-MEMBER-CUT',
		'unit.check.OperandBindingTest#testMemberReturnOfIndexedClassIsProven :: control :: M-NULLITY-RETURN-CUT',
		'unit.check.OperandBindingTest#testMemberReturnPathIsNotItsLastSegment :: control :: M-NULLITY-RETURN-LAST-SEGMENT',
		'unit.check.OperandBindingTest#testMemberReturnWithOverloadIsUnproven :: control :: M-NULLITY-RETURN-OVERLOAD',
		'unit.check.OperandBindingTest#testMemberTypeBindsInItsDeclaringFile :: control :: M-OPERAND-MEMBER-SCOPE-LOST',
		'unit.check.OperandBindingTest#testMethodTypeParameterIsNotTheSamePackageClass :: control :: M-OPERAND-METHOD-PARAMS-IGNORED',
		'unit.check.OperandBindingTest#testNegationRulesBindTheOperands :: control :: M-BINDING-UNINDEXED-IMPORT-FREE',
		'unit.check.OperandBindingTest#testNullableOverloaderIsOverloaded :: control :: M-OPERAND-WRAPPER-KEPT',
		'unit.check.OperandBindingTest#testOverloadMetaIsIndexed :: control :: M-INDEX-OVERLOAD-META',
		'unit.check.OperandBindingTest#testOverloadedSignatureIsNotItsWrittenReturn :: control :: M-OPERAND-OVERLOAD-SIGNATURE',
		'unit.check.OperandBindingTest#testSamePackageClassIsProven :: control :: M-BINDING-PACKAGE-TIER-CUT',
		'unit.check.OperandBindingTest#testShadowedStringIsNotTheBuiltin :: control :: M-TOSTRING-STRING-BINDING',
		'unit.check.OperandBindingTest#testStaticCallThroughTypeNameIsProven :: control :: M-OPERAND-STATIC-RECEIVER-CUT',
		'unit.check.OperandBindingTest#testSubTypeOfUnindexedModuleOutranksSamePackageClass :: control :: M-BINDING-UNINDEXED-MODULE-FREE',
		'unit.check.OperandBindingTest#testToStringCallReceiverBindsItsOwner :: control :: M-TOSTRING-CALL-BY-NAME',
		'unit.check.OperandBindingTest#testToStringCallReceiverOfIndexedOwnerIsProven :: control :: M-TOSTRING-CALL-CUT',
		'unit.check.OperandBindingTest#testToStringIdentReceiverOfIndexedClassIsProven :: control :: M-TOSTRING-IDENT-CUT',
		'unit.check.OperandBindingTest#testUndecidedCaptureShadowsTheOuterBinding :: control :: M-OPERAND-CASE-CAPTURE',
		'unit.check.OperandBindingTest#testWildcardOverUnindexedPackageOutranksSamePackageClass :: control :: '
			+ 'M-BINDING-UNINDEXED-WILDCARD-FREE',
		'unit.check.OperandTypingTest#testACalleeWhoseSignatureTheCallMayNotSelectIsUnproven :: control :: '
			+ 'M-BINDER-ARGUMENT-OVERLOAD,M-BINDER-ARGUMENT-TWIN',
		'unit.check.OperandTypingTest#testACalleesTypeParameterTypesNoLambda :: control :: M-BINDER-ARGUMENT-SCOPE',
		'unit.check.OperandTypingTest#testAFixAsksTheRunsOperatorTable :: control :: '
			+ 'M-FOLD-FIX-REPORT-INDEX,M-PIEC-FIX-REPORT-INDEX,M-PIEC-RUN-SELECTION',
		'unit.check.OperandTypingTest#testAGuardedUsingLeavesTheExtensionUnproven :: control :: M-BINDER-EXTENSION-GUARDED-USING',
		'unit.check.OperandTypingTest#testALambdaAfterASkippableParameterIsUnproven :: control :: '
			+ 'M-BINDER-ARGUMENT-SKIPPABLE,M-TS-SKIP-DEFAULT',
		'unit.check.OperandTypingTest#testALambdaTakesTheParameterOfACalleeDeclaredElsewhere :: control :: M-BINDER-CALLEE-MEMBER-OFF,M-BINDER-CALLEE-NEW-OFF,M-BINDER-CALLEE-INHERITED-OFF,M-BINDER-CALLEE-LOCAL-OFF,M-BINDER-OWNER-BINDINGS-OFF,M-BINDER-LOCATED-HOST-OFF',
		'unit.check.OperandTypingTest#testAStaticOfTheFieldsNameOutranksTheResolver :: control :: '
			+ 'M-BINDER-RESOLVE-USING-SHADOW,M-USING-DECLS-AMBIENT',
		'unit.check.OperandTypingTest#testAStdIterableBindsTheElementOfWhatIsHandedToIt :: control :: M-BINDER-ITERABLE-OFF,M-BINDER-ITERABLE-ANY-TYPE',
		'unit.check.OperandTypingTest#testASupertypeStaticReadBareIsNotTheSupertypes :: control :: M-BINDER-INHERITED-STATIC',
		'unit.check.OperandTypingTest#testAUsedAliasLeavesTheExtensionUnproven :: control :: M-USING-HOSTS-ALIAS',
		'unit.check.OperandTypingTest#testAnExtensionOfAnotherFirstParameterIsUnproven :: control :: M-BINDER-EXTENSION-FIRST-PARAM',
		'unit.check.OperandTypingTest#testAnInheritedMemberPastAnUnreadSupertypeIsUnproven :: control :: M-BINDER-CLOSURE-UNRESOLVED',
		'unit.check.OperandTypingTest#testAnUnreadLaterUsingLeavesTheExtensionUnproven :: control :: M-BINDER-EXTENSION-UNINDEXED',
		'unit.check.OperandTypingTest#testAnUntypedLambdaParameterTakesTheCalleesParameterType :: control :: '
			+ 'M-BINDER-LAMBDA-PARAM-CUT,M-WALK-LAMBDA-PARAM-CUT,M-BINDER-ARGUMENT-CUT',
		'unit.check.OperandTypingTest#testEveryConcatenationUserAnswersTheSameOnTheSameOperand :: control :: '
			+ 'M-BINDER-INITIALIZER-CUT,M-BINDER-EXTENSION-CUT,M-BINDER-RESOLVE-CUT',
		'unit.check.OperandTypingTest#testEveryEqualityUserAnswersTheSameOnTheSameOperand :: control :: M-BINDER-INITIALIZER-CUT',
		'unit.check.OperandTypingTest#testEveryExpectationTypesTheLambdaParameter :: control :: '
			+ 'M-BINDER-LAMBDA-PARAM-CUT,M-BINDER-ANNOTATION-CUT,M-BINDER-RETURN-CUT,M-BINDER-FIELD-CUT,M-BINDER-ARGUMENT-CUT,'
			+ 'M-GRAPH-LITERAL-ARGUMENT,M-GRAPH-LITERAL-ARMS,M-GRAPH-LITERAL-RETURN,M-GRAPH-LITERAL-LAMBDA,M-GRAPH-LITERAL-FIELD,'
			+ 'M-TS-LAMBDA-NULL,M-BINDER-ARGUMENT-REST',
		'unit.check.OperandTypingTest#testEveryNegationFormAnswersTheSameOnTheSameOperand :: control :: '
			+ 'M-BINDER-INITIALIZER-CUT,M-BINDER-SELF-CUT,M-BINDER-INHERITED-CUT,M-BINDER-EXTENSION-CUT,M-BINDER-RESOLVE-CUT',
		'unit.check.OperandTypingTest#testEveryTypeOfAUsedModuleBringsItsExtensions :: control :: M-USING-HOSTS-MODULE',
		'unit.check.OperandTypingTest#testTheLastUsingDeclaringTheExtensionWins :: control :: M-BINDER-EXTENSION-LAST-USING',
		'unit.check.OperandTypingTest#testTheReceiversOwnUsingOutranksTheFiles :: control :: M-BINDER-EXTENSION-ATUSING',
		'unit.check.OperandTypingTest#testWhatTheCallDoesNotBindStaysUnproven :: control :: M-BINDER-METHOD-SHADOWS-OFF,M-BINDER-CALLEE-OVERLOAD',
		'unit.check.OperatorOverloadGateTest#testDefaultLastAsksTheOperatorItWrites :: control :: '
			+ 'M-NEGCOND-DEFAULT-LAST-OVERLOAD-BLIND,M-NEGCOND-DEFAULT-LAST-EQ-UNASKED',
		'unit.check.OperatorOverloadGateTest#testInvertTernarySkipsOverloadedNot :: control :: M-NEGCOND-OVERLOAD-BLIND',
		'unit.check.OperatorOverloadGateTest#testTernaryReturnKeepsOverloadedNot :: control :: '
			+ 'M-NEGCOND-OVERLOAD-BLIND,M-OPSEL-REPORT-DROPPED',
		'unit.check.OptionalParamShorthandCheckTest#testCommentInsideTheWrapperIsKept :: control :: M-OPTPARAM-COMMENT-DROPPED',
		'unit.check.OracleAssistedRefusalTest#testARefusedFindingCostsItsAssistedRuleNothingElse :: control :: '
			+ 'M-ASSISTED-SPLIT-NONE,M-ASSISTED-SALVAGE-NONE,M-ASSISTED-SALVAGED-COUNT-ALL',
		'unit.check.OracleAssistedRefusalTest#testAnAssistedRefusalIsReported :: control :: '
			+ 'M-ASSISTED-REFUSAL-SILENT,M-ASSISTED-REFUSAL-LEDGER-NONE',
		'unit.check.OracleBatchRevertReasonTest#testTheBatchBlamesTheFileTheCompilerNames :: control :: M-BLAMES-BASENAME',
		'unit.check.OracleCacheTest#testAFingerprintReadsItsSourcesThroughTheMemo :: control :: M-ORACLE-CACHE-MEMO-UNREAD',
		'unit.check.OracleCacheTest#testAVerdictIsNotFiledUnderAFingerprintTheTreeLeft :: control :: '
			+ 'M-ORACLE-CACHE-STORES-A-MOVED-FINGERPRINT',
		'unit.check.OracleCacheTest#testFingerprintsSharingOneWalkEqualTheirOwn :: control :: M-ORACLE-CACHE-WALK-FIRST-ONLY',
		'unit.check.OracleCacheTest#testHxmlArgsReadTheLinesAsTheCompilerDoes :: control :: M-HXML-SPLIT-LAST-SPACE,M-HXML-QUOTES-KEPT',
		'unit.check.OracleCacheTest#testHxmlRefsReadsCpLibAndIncludes :: control :: M-HXML-SPLIT-LAST-SPACE',
		'unit.check.OracleConfigListE2ETest#testAConfigurationWithAnUnknownCompiledSetStillVetoesAnEdit :: control :: '
			+ 'M-ORACLE-UNKNOWN-COVERAGE-NO-VETO',
		'unit.check.OracleConfigListE2ETest#testARedBaselineExcludesItsConfigurationRatherThanThePhase :: control :: '
			+ 'M-ORACLE-RED-BASELINE-STOPS-THE-PHASE',
		'unit.check.OracleConfigListE2ETest#testARedConfigurationWhoseErrorLineMovesIsNamedOnce :: control :: '
			+ 'M-ORACLE-EXCLUSIONS-KEYED-BY-SENTENCE',
		'unit.check.OracleConfigListE2ETest#testASafeOnlyRunNamesTheConfigurationItsNetRanWithout :: control :: '
			+ 'M-ORACLE-EXCLUSIONS-UNNAMED',
		'unit.check.OracleConfigListE2ETest#testASeededProbeAnswersOnlyForItsOwnConfiguration :: control :: '
			+ 'M-ORACLE-COVERAGE-PAIRED-BY-INDEX',
		'unit.check.OracleConfigListE2ETest#testAnEditTheSecondConfigurationRejectsIsReverted :: control :: '
			+ 'M-ORACLE-FIRST-CONFIGURATION-IS-ENOUGH',
		'unit.check.OracleConfigListE2ETest#testAnUnknownCompiledSetExcludesItsConfigurationRatherThanThePhase :: control :: '
			+ 'M-ORACLE-UNKNOWN-COVERAGE-STOPS-THE-PHASE',
		'unit.check.OracleConfigListE2ETest#testTheDisplayServerAnswersForTheConfigurationItServes :: control :: '
			+ 'M-DISPLAY-ORACLE-DROPS-DEFINES',
		'unit.check.OracleDirTest#testASingleTypecheckRunsInTheDeclaredDir :: control :: M-SPAWN-RUN-IGNORES-CWD',
		'unit.check.OracleDirTest#testOverlappedTypechecksRunInTheDeclaredDir :: control :: M-SPAWN-RUNALL-IGNORES-CWD',
		'unit.check.OracleDirTest#testTheDisplayServerWarmsInTheDeclaredDir :: control :: M-DISPLAY-IGNORES-DIR',
		'unit.check.OracleDirTest#testTheFingerprintReadsTheClasspathUnderTheDeclaredDir :: control :: M-ORACLE-CACHE-IGNORES-DIR',
		'unit.check.OracleDirTest#testTheProbesRunInTheDeclaredDir :: control :: M-SPAWN-RUN-IGNORES-CWD',
		'unit.check.OracleGcTest#testATunedCollectorCostsMemory :: guard :: M-GC-MEMORY-UNCOUNTED',
		'unit.check.OracleGcTest#testEveryKindOfSpawnRunsUnderTheDefault :: control :: '
			+ 'M-GC-RUN-INHERITS,M-GC-DRIVER-INHERITS,M-GC-PENDING-INHERITS',
		'unit.check.OracleGcTest#testTheCallersOwnSettingStaysAndOffAddsNothing :: guard :: M-GC-INHERITED-OVERRIDDEN,M-GC-OFF-IGNORED',
		'unit.check.OracleGcTest#testTheParameters :: guard :: M-GC-OFF-IGNORED,M-GC-EMPTY-DECLARED-OFF,M-GC-INHERITED-OVERRIDDEN',
		'unit.check.OracleGenerationTest#testAChangedCommandRegenerates :: control :: M-GENERATE-NEVER-STALE-BY-COMMAND',
		'unit.check.OracleGenerationTest#testAChangedInputRegeneratesAndAnUnchangedOneDoesNot :: control :: '
			+ 'M-GENERATE-NEVER-STALE-BY-INPUT',
		'unit.check.OracleGenerationTest#testACommandThatWritesItsOwnInputIsUsable :: control :: M-GENERATE-SHARE-JUDGES-STALENESS',
		'unit.check.OracleGenerationTest#testADevLibraryIsTrackedThroughItsRepositoryDirectory :: control :: '
			+ 'M-GENERATE-REPO-DIR-FROM-NAME',
		'unit.check.OracleGenerationTest#testADirectoryInputIsHashedByItsContent :: control :: M-GENERATE-DIRECTORY-INPUT-CONSTANT',
		'unit.check.OracleGenerationTest#testAFailedGenerationIsUnavailableNeverTheStaleHxml :: control :: '
			+ 'M-GENERATE-FAILURE-USES-THE-STALE-HXML',
		'unit.check.OracleGenerationTest#testAFileNamedByTwoGenerationsIsReadOnce :: control :: M-GENERATE-HASH-MEMO-UNUSED',
		'unit.check.OracleGenerationTest#testAGenerationThatKeepsGoingStaleIsUnavailable :: control :: M-GENERATE-REJUDGE-UNBOUNDED',
		'unit.check.OracleGenerationTest#testAHalfWrittenOwnerIsNotTakenOver :: control :: M-GENERATE-OWNERLESS-ABANDONED-AT-ONCE',
		'unit.check.OracleGenerationTest#testAJobWithoutAStartTimeIsLeftAlone :: control :: M-GENERATE-ENDJOB-PID-ONLY',
		'unit.check.OracleGenerationTest#testALeftoverTakeoverClaimIsCleared :: control :: M-GENERATE-CLAIM-NEVER-CLEARED',
		'unit.check.OracleGenerationTest#testALibrarySwitchedDuringTheGenerationIsSeenNextRun :: control :: '
			+ 'M-GENERATE-IMPLICIT-HASHED-AFTER-THE-RUN',
		'unit.check.OracleGenerationTest#testALiveReaderDoesNotBlockACurrentGeneration :: control :: '
			+ 'M-GENERATE-READERS-EXCLUDE-EACH-OTHER',
		'unit.check.OracleGenerationTest#testALiveReaderHoldsOffARegeneration :: control :: M-GENERATE-WRITER-IGNORES-READERS',
		'unit.check.OracleGenerationTest#testALockHeldByALiveRunMakesTheConfigurationUnavailable :: control :: M-GENERATE-LOCK-IGNORED',
		'unit.check.OracleGenerationTest#testAMarkerInTheOutputTreeDoesNotHoldTheState :: control :: '
			+ 'M-GENERATE-STATE-IN-OUTPUT-DIR,M-GENERATE-STATE-ROOT-FROM-HXML',
		'unit.check.OracleGenerationTest#testAMissingHxmlRegenerates :: control :: M-GENERATE-TRUSTS-A-MISSING-HXML',
		'unit.check.OracleGenerationTest#testARacedGenerationDoesNotVerifyFixes :: control :: M-GENERATE-RACED-VERIFIES-FIXES',
		'unit.check.OracleGenerationTest#testAReadOnlyRootIsUnavailableNotACrash :: control :: M-GENERATE-READ-ONLY-ROOT-THROWS',
		'unit.check.OracleGenerationTest#testARecordOfAnOlderSchemeIsStale :: control :: M-GENERATE-FORMAT-UNCHECKED',
		'unit.check.OracleGenerationTest#testAReusedPidDoesNotHoldTheLock :: control :: M-GENERATE-PID-ALONE',
		'unit.check.OracleGenerationTest#testAStaleGenerationRunsWithoutItsOldRecord :: control :: M-GENERATE-RECORD-OUTLIVES-THE-RUN',
		'unit.check.OracleGenerationTest#testATakeOverEndsTheJobTheDeadRunLeft :: control :: M-GENERATE-TAKEOVER-LEAVES-THE-JOB',
		'unit.check.OracleGenerationTest#testATopLevelHxmlKeepsItsStateInItsOwnProject :: control :: M-GENERATE-STATE-ROOT-FROM-HXML',
		'unit.check.OracleGenerationTest#testATreeAnotherCommandRegeneratedIsUnavailableAtOnce :: control :: '
			+ 'M-GENERATE-RIVAL-COMMAND-RETRIED',
		'unit.check.OracleGenerationTest#testATreeWipedAfterItWasJudgedIsRegeneratedBeforeTheCompile :: control :: '
			+ 'M-GENERATE-SHARE-WITHOUT-REJUDGE',
		'unit.check.OracleGenerationTest#testAnAbandonedLockIsTakenOver :: control :: M-GENERATE-LOCK-NEVER-RECOVERED',
		'unit.check.OracleGenerationTest#testAnEmptyOrMissingInputIsNeverSilentlyConstant :: control :: '
			+ 'M-GENERATE-EMPTY-INPUTS-NEVER,M-GENERATE-MISSING-INPUT-SILENT',
		'unit.check.OracleGenerationTest#testAnEntryWithNoInputsRegeneratesOncePerRunAndIsUsable :: control :: '
			+ 'M-GENERATE-SHARE-JUDGES-STALENESS',
		'unit.check.OracleGenerationTest#testAnHxmlTheGenerationWritesIsNotARacedInput :: control :: M-GENERATE-PRODUCED-INCLUDE-IS-INPUT',
		'unit.check.OracleGenerationTest#testAnHxmlTwoCommandsGenerateIsDropped :: control :: M-GENERATE-RIVAL-COMMANDS-KEPT',
		'unit.check.OracleGenerationTest#testAnIncludeOutsideTheHxmlTreeIsAnInput :: control :: M-GENERATE-PRODUCED-BY-ROOT',
		'unit.check.OracleGenerationTest#testAnInputEditedDuringTheGenerationIsSeenNextRun :: control :: '
			+ 'M-GENERATE-HASHES-INPUTS-AFTER-THE-RUN',
		'unit.check.OracleGenerationTest#testAnotherRunsGenerationMovesTheSnapshot :: control :: M-GENERATE-EPOCH-UNOBSERVED',
		'unit.check.OracleGenerationTest#testEntriesSharingACommandMergeTheirInputs :: control :: M-GENERATE-FIRST-ENTRY-INPUTS',
		'unit.check.OracleGenerationTest#testEveryConfigOverOneTreeMeetsOneLock :: control :: '
			+ 'M-GENERATE-STATE-BY-CONFIG-ROOT,M-GENERATE-STATE-BY-SPELLING,M-GENERATE-STATE-IN-OUTPUT-DIR',
		'unit.check.OracleGenerationTest#testGenerationsAreWaitedOnInLockOrder :: control :: M-GENERATE-ORDER-BY-KEY',
		'unit.check.OracleGenerationTest#testOnlyOneRunTakesOverADeadLock :: control :: M-GENERATE-TAKEOVER-UNVERIFIED',
		'unit.check.OracleGenerationTest#testTheGenerationStateIgnoresItself :: control :: '
			+ 'M-GENERATE-IGNORE-OVERWRITTEN,M-GENERATE-STATE-NOT-IGNORED',
		'unit.check.OracleGenerationTest#testTheGenerationStateIsSharedAcrossTempDirectories :: control :: M-GENERATE-STATE-IN-TMPDIR',
		'unit.check.OracleGenerationTest#testTheLibraryStateTheHxmlNamesIsAnInput :: control :: '
			+ 'M-GENERATE-IGNORES-LIBRARY-STATE,M-GENERATE-TEMPLATES-UNTRACKED',
		'unit.check.OracleGenerationTest#testTheOracleRunCountsTheUnavailable :: control :: M-ORACLE-SUMMARY-SILENT',
		'unit.check.OracleGenerationTest#testTheStateDirectoryIsNoInput :: control :: M-GENERATE-STATE-DIR-HASHED',
		'unit.check.OracleGenerationTest#testTwoRunsOverTwoStaleGenerationsDoNotDeadlock :: control :: '
			+ 'M-GENERATE-SHARED-HELD-INTO-PHASE-TWO',
		'unit.check.OracleGenerationTest#testTwoSpellingsOfOneHxmlAreOneClaim :: control :: M-GENERATE-RIVAL-BY-SPELLING',
		'unit.check.OracleParallelVerdictTest#testTheOverlappedVerdictIsTheFirstFailureInDeclaredOrder :: control :: '
			+ 'M-DRIVER-CANCELS-EARLIER-JOBS',
		'unit.check.OracleParallelismTest#testMemoryTheCapAndOneBoundTheBudget :: guard :: ',
		'unit.check.OracleParallelismTest#testTheBudgetIsEveryCoreButOne :: control :: M-ORACLE-PARALLEL-HALF-THE-CORES',
		'unit.check.OracleRunMemoTest#testACompileWhoseInputMovedIsNotFiled :: control :: M-RUNMEMO-FILES-A-MOVED-INPUT',
		'unit.check.OracleRunMemoTest#testAConfigurationOutsideARunIsAlwaysCompiled :: guard :: ',
		'unit.check.OracleRunMemoTest#testARejectedBaselineQuotesThePlainCompile :: control :: M-RUNMEMO-QUOTES-THE-VERBOSE-STREAMS',
		'unit.check.OracleRunMemoTest#testASourceTheFingerprintCannotSeeIsAlwaysCompiled :: control :: M-RUNMEMO-TRUSTS-UNSEEN-SOURCES',
		'unit.check.OracleRunMemoTest#testAVerdictIsReusedForTheSameContentOnly :: control :: M-RUNMEMO-KEY-IGNORES-CONTENT',
		'unit.check.OracleRunMemoTest#testAWarmRejectionIsCompiledAgainCold :: control :: M-POOL-TRUSTS-WARM-RED',
		'unit.check.OracleRunMemoTest#testAWarmServerDiesWithItsDriver :: control :: M-POOL-SERVER-UNTETHERED',
		'unit.check.OracleRunMemoTest#testAWarmServerReadsATreeRewrittenWithinTheSecond :: control :: M-POOL-NO-INVALIDATE',
		'unit.check.OracleRunMemoTest#testTheCoverageProbeReusesTheBaselineCompile :: control :: M-RUNMEMO-PROBE-RECOMPILES',
		'unit.check.OracleRunMemoTest#testTheFactsCompileBringsTheBaselineAlong :: control :: M-RUNMEMO-NO-BASELINE-AHEAD',
		'unit.check.OracleRunMemoTest#testTheSafeWriteNetCompilesTheTreeTheCoverageProbeAsksAbout :: control :: M-SAFE-NET-PLAIN',
		'unit.check.OracleRunWiringTest#testAFixRunGivenEveryRuleStartsTheFactsEarly :: control :: M-FACTS-NEVER-EARLY',
		'unit.check.OracleRunWiringTest#testALintRunCompilesEachTreeOnce :: control :: M-RUNMEMO-NOT-ATTACHED',
		'unit.check.OracleRunWiringTest#testAReportANarrowedOrAnOracleLessRunAsksOnDemand :: guard :: ',
		'unit.check.OracleRunWiringTest#testAnEditReachedThroughALibraryIsCompiled :: control :: M-RUNMEMO-WRITTEN-UNHASHED',
		'unit.check.OracleRunWiringTest#testUnaskedEarlyFactsLeaveNothingBehind :: control :: M-FACTS-EARLY-DIRS-LEFT',
		'unit.check.OrphanAccessorCheckTest#testAnUnreadableCallerOutsideTheReportScopeStillDeclinesTheDeletion :: control :: '
			+ 'M-ORPHAN-UNREADABLE-REPORT-SCOPE,M-ORPHAN-FIX-UNREADABLE-BLIND',
		'unit.check.OrphanAccessorCheckTest#testAnUnreadableProjectFileSpellingNothingLeavesTheDeletionAvailable :: control :: '
			+ 'M-ORPHAN-UNREADABLE-ANY-FILE',
		'unit.check.OrphanAccessorCheckTest#testAnUnreadableSubtypeOutsideTheReportScopeStillDowngradesTheReport :: control :: '
			+ 'M-ORPHAN-UNREADABLE-REPORT-SCOPE,M-ORPHAN-REPORT-UNREADABLE-BLIND',
		'unit.check.OrphanAccessorCheckTest#testAnUnreadableThirdPartyFileSpellingTheAccessorStillDeclines :: control :: '
			+ 'M-ORPHAN-UNREADABLE-REFLECTIVE-NARROWED',
		'unit.check.OrphanAccessorCheckTest#testAnUnreadableThirdPartySubtypeDoesNotDeclineAProjectDeletion :: control :: '
			+ 'M-ORPHAN-UNREADABLE-SUBTYPE-OWNER-WIDE,M-ORPHAN-REPORT-OWNER-WIDE',
		'unit.check.OrphanAccessorCheckTest#testTheUnresolvedSupertypeArmAlsoSaysWhyNoEditFollows :: control :: '
			+ 'M-ORPHAN-ARMS-SHARE-REASON',
		'unit.check.OversizedTypeCheckTest#testACeilingLessGrantIsRefusedWithAMigrationMessage :: control :: '
			+ 'M-OVERSIZED-LEGACY-GRANT,M-OVERSIZED-PROBLEM-SILENT',
		'unit.check.OversizedTypeCheckTest#testACeilingNotAboveTheThresholdIsRefused :: control :: M-OVERSIZED-CEILING-AT-THRESHOLD',
		'unit.check.OversizedTypeCheckTest#testAConstantTableIsNotReported :: control :: M-OVERSIZED-CONST-COUNTED',
		'unit.check.OversizedTypeCheckTest#testAGrantWithoutAReasonIsRefused :: control :: M-OVERSIZED-GRANT-REASONLESS',
		'unit.check.OversizedTypeCheckTest#testALineAConstantSharesWithBehaviourCounts :: control :: M-OVERSIZED-CONST-SHARED-LINE',
		'unit.check.OversizedTypeCheckTest#testAMalformedGrantIsRefused :: control :: '
			+ 'M-OVERSIZED-GRANT-NAME,M-OVERSIZED-CLAUSE-ORDER,M-OVERSIZED-CLAUSE-REPEATED,M-OVERSIZED-CEILING-DIGITS',
		'unit.check.OversizedTypeCheckTest#testAMixedTypeKeepsItsBehaviourCount :: control :: M-OVERSIZED-CONST-COUNTED',
		'unit.check.OversizedTypeCheckTest#testARefusedGrantIsReportedOncePerRun :: control :: M-OVERSIZED-PROBLEM-ONCE',
		'unit.check.OversizedTypeCheckTest#testAnUngrantedDimensionKeepsTheThreshold :: control :: M-OVERSIZED-UNGRANTED-DIMENSION',
		'unit.check.OversizedTypeCheckTest#testEveryConstantShapeIsUncounted :: control :: '
			+ 'M-OVERSIZED-CONST-INLINE-PROOF,M-CONST-EXPR-NO-OPERATORS,M-CONST-EXPR-NO-PARENS,'
			+ 'M-CONST-EXPR-NO-NAMES,M-OVERSIZED-CONST-NO-ENUM-VALUES,M-OVERSIZED-CONST-ENUM-VALUE-NEEDS-INIT',
		'unit.check.OversizedTypeCheckTest#testEveryNonConstantShapeCounts :: control :: M-OVERSIZED-CONST-NEEDS-STATIC,'
			+ 'M-OVERSIZED-CONST-STATIC-VAR,M-OVERSIZED-CONST-ANY-STATIC-FINAL,M-OVERSIZED-CONST-ACCESSOR,M-OVERSIZED-CONST-ANY-ENUM-HOST,'
			+ 'M-OVERSIZED-CONST-NAME-NOT-CONSTANT,M-OVERSIZED-CONST-NAME-UNDECLARED,M-CONST-EXPR-ANY-OPERAND,M-CONST-EXPR-INTERPOLATED',
		'unit.check.OversizedTypeCheckTest#testGrantPastItsCeilingReportsTheTypeAgain :: control :: '
			+ 'M-OVERSIZED-GRANT-UNBOUNDED,M-OVERSIZED-BEYOND-UNNAMED',
		'unit.check.OversizedTypeCheckTest#testLineCeilingIsJudgedOnItsOwn :: control :: M-OVERSIZED-GRANT-LINES-UNBOUNDED',
		'unit.check.OversizedTypeCheckTest#testTheLinesOfAConstantAreNotCounted :: control :: '
			+ 'M-OVERSIZED-CONST-LINES-COUNTED,M-OVERSIZED-CONST-REGION-OWN-LINES',
		'unit.check.OversizedTypeCheckTest#testTheLinesOfBehaviourStillCount :: control :: M-OVERSIZED-CONST-LINES-COUNTED',
		'unit.check.OversizedTypeCheckTest#testTwoGrantsForOneTypeAreBothRefused :: control :: M-OVERSIZED-DUPLICATE-GRANT',
		'unit.check.OwnedTypesCheckTest#testAGuardedImportBindsAUseInItsOwnBranch :: control :: '
			+ 'M-OWNED-TIER-NO-USE-SITE,M-OWNED-MEMO-IGNORES-SITE',
		'unit.check.OwnedTypesCheckTest#testALocalInitialisedByAConstructionIsTyped :: control :: '
			+ 'M-NOMINAL-LOCAL-CONSTRUCTION,M-NOMINAL-INITIALIZER-ONE-STEP',
		'unit.check.OwnedTypesCheckTest#testANameNoTierBindsIsNotReported :: control :: M-OWNED-FREE-REPORTED',
		'unit.check.OwnedTypesCheckTest#testAQualifiedExpressionIsAMention :: control :: M-OWNED-QUALIFIED-EXPR-IGNORED',
		'unit.check.OwnedTypesCheckTest#testASameNamedTypeOfAnotherPackageIsNotReported :: control :: M-OWNED-BOUND-BY-NAME',
		'unit.check.OwnedTypesCheckTest#testAStaticMemberIsReachedThroughItsType :: control :: M-OWNED-STATIC-THROUGH-SUBTYPE',
		'unit.check.OwnedTypesCheckTest#testAValueNamedLikeTheTypeIsNotReported :: control :: M-OWNED-VALUE-IS-TYPE',
		'unit.check.OwnedTypesCheckTest#testAnImportAndAnAliasAreMentions :: control :: M-OWNED-IMPORTS-IGNORED,M-OWNED-ALIAS-IGNORED',
		'unit.check.OwnedTypesCheckTest#testAnInstanceMemberIsReachedThroughATypedReceiver :: control :: M-OWNED-NO-SUPERTYPE-WALK',
		'unit.check.OwnedTypesCheckTest#testAnOutsideCandidateIsMatchedByItsPath :: control :: M-OWNED-OUTSIDE-CANDIDATE-IGNORED',
		'unit.check.OwnedTypesCheckTest#testAnOwnerTypeOwnsItsOwnBody :: control :: M-OWNED-ENCLOSING-TYPE',
		'unit.check.OwnedTypesCheckTest#testAnUnknownReceiverIsReportedForAStaticOnly :: control :: '
			+ 'M-OWNED-STATIC-UNKNOWN-SILENT,M-OWNED-UNKNOWN-SILENT,M-OWNED-INSTANCE-BY-NAME',
		'unit.check.OwnedTypesCheckTest#testAnUnknownReceiverIsReportedOnlyWhenACandidateIsOwned :: control :: '
			+ 'M-OWNED-CANDIDATES-IGNORED,M-BINDING-EITHER-DROPS-GUARDED',
		'unit.check.OwnedTypesCheckTest#testAnUnresolvableMentionIsReported :: control :: M-OWNED-UNKNOWN-SILENT',
		'unit.check.OwnedTypesCheckTest#testConstructionIsTheNewMember :: control :: M-OWNED-CTOR-ANY-TYPE',
		'unit.check.OwnedTypesCheckTest#testNoDeclarationIsInert :: control :: M-OWNED-SKIP-REASON-NULL',
		'unit.check.OwnedTypesCheckTest#testOwnersArePackageGlobs :: control :: M-OWNED-OWNERS-IGNORED',
		'unit.check.OwnedTypesCheckTest#testTheDeclaringModuleOwnsItsType :: control :: M-OWNED-DECLARING-MODULE',
		'unit.check.OwnedTypesCheckTest#testTheReaderNamesEveryDrop :: control :: M-OWNED-READER-NO-OWNERS,M-OWNED-PARSE'
	];

}
