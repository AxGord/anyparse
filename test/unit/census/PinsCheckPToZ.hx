package unit.census;

/**
 * Part of the pin census `unit.PinCensusParityTest` compares with `TestRegistry.pins()`:
 * the pins from `'unit.check.P'` up to `'unit.cli.'`: the rule tests `unit.check.P*`..`Z*`
 *
 * SORTED, in code-unit order (`TestRegistry.pins()` sorts so): a new pin goes into the part
 * whose range holds it, at its sorted place — `hxq add-element test/unit/census/PinsCheckPToZ.hx --sorted
 * --select 'FinalMember:PINS >> ArrayExpr' "'<entry>'" --write`. The parts concatenate in
 * range order, so an entry in the wrong part fails the census as a misordered list.
 */
@:nullSafety(Strict)
final class PinsCheckPToZ {

	public static final PINS: Array<String> = [
		'unit.check.PendingRunsTest#testABatchRunsWhileTheCallerWorks :: control :: M-PENDING-RUNS-IN-FOREGROUND',
		'unit.check.PendingRunsTest#testACancelledBatchEndsItsJobs :: control :: M-PENDING-CANCEL-LEAVES-JOBS',
		'unit.check.PendingRunsTest#testATetheredJobDiesWithItsDriver :: control :: M-TETHER-IGNORES-EOF',
		'unit.check.PendingRunsTest#testAWedgedBackgroundDriverIsKilledAtItsBound :: control :: M-PENDING-UNBOUNDED',
		'unit.check.PendingRunsTest#testTheBatchFilesArePrivateAndShortLived :: control :: M-PENDING-JOBS-FILE-KEPT',
		'unit.check.PossibleNullDereferenceTest#testCallReturnPopFlagged :: control :: M-NULLABLE-NO-CHAIN',
		'unit.check.PossibleNullDereferenceTest#testExistsGuardedEarlyReturnNotFlagged :: control :: M-EXISTS-GUARD-BLIND',
		'unit.check.PossibleNullDereferenceTest#testExistsGuardedThenArmNotFlagged :: control :: M-EXISTS-GUARD-BLIND',
		'unit.check.PossibleNullDereferenceTest#testFieldPathMapExistsGuardedNotFlagged :: control :: M-EXISTS-GUARD-BLIND',
		'unit.check.PossibleNullDereferenceTest#testFieldPathMapReceiverFlagged :: control :: M-NULLABLE-NO-CHAIN',
		'unit.check.PossibleNullDereferenceTest#testNullWrappedMapFlagged :: control :: M-NULLABLE-WRAPPER-OPAQUE',
		'unit.check.PossibleNullDereferenceTest#testRereadMapEntryAfterAChangeStillFlagged :: control :: M-NULLFLOW-VALUE-FACT-UNKILLED',
		'unit.check.PossibleNullDereferenceTest#testRereadMapEntryNotFlagged :: control :: M-NULLFLOW-VALUE-FACT-BLIND',
		'unit.check.PreferApiIdiomCheckTest#testACommentInTheWindowRefuses :: control :: M-IDIOM-NO-COMMENT-GATE',
		'unit.check.PreferApiIdiomCheckTest#testAGetterHopInTheReceiverRefuses :: control :: M-IDIOM-GETTER-HOP',
		'unit.check.PreferApiIdiomCheckTest#testASubclassReceiverRefusesUnlessDeclared :: control :: M-IDIOM-SUBTYPES-ALWAYS',
		'unit.check.PreferApiIdiomCheckTest#testAnImpureRightHandSideRefuses :: control :: M-IDIOM-NO-PURITY',
		'unit.check.PreferApiIdiomCheckTest#testReadingAFieldWrittenAboveRefuses :: control :: M-IDIOM-NO-EARLIER-READ-GATE',
		'unit.check.PreferApiIdiomCheckTest#testReadingThatFieldThroughAnotherReceiverRefuses :: control :: M-IDIOM-NO-EARLIER-READ-GATE',
		'unit.check.PreferApiIdiomCheckTest#testTheIndexRefutesADeclarationThatCannotBeTrue :: control :: M-IDIOM-VALIDATE-TRUSTS',
		'unit.check.PreferApiIdiomCheckTest#testTheReaderNamesEveryDroppedEntry :: control :: M-IDIOM-READER-LENIENT',
		'unit.check.PreferApiIdiomCheckTest#testTheTypesOwnBodyIsNeverRewritten :: control :: M-IDIOM-NO-SELF-TYPE-GATE',
		'unit.check.PreferBindCheckTest#testAbstractInstanceMethodNotFlagged :: control :: M-BIND-ABSTRACT-SELF',
		'unit.check.PreferBindCheckTest#testClosurelessCalleeNotFlagged :: control :: M-BIND-METHOD-UNPROVEN,M-BIND-CLOSURELESS-CALLEE',
		'unit.check.PreferBindCheckTest#testFieldArgumentNotFlagged :: control :: M-BIND-FIELD-ARG',
		'unit.check.PreferBindCheckTest#testFieldReceiverNotFlagged :: control :: M-BIND-FIELD-RECEIVER',
		'unit.check.PreferBindCheckTest#testLibraryOrExternCalleeNotFlagged :: control :: M-BIND-LIBRARY-CALLEE,M-BIND-EXTERN-TYPE',
		'unit.check.PreferBindCheckTest#testNullableArgumentNotFlagged :: control :: M-BIND-NULLABLE-ARG',
		'unit.check.PreferBindCheckTest#testReassignedLocalNotFlagged :: control :: M-BIND-WRITES-IGNORED',
		'unit.check.PreferBindCheckTest#testRebindableCalleeNotFlagged :: control :: M-BIND-METHOD-UNPROVEN,M-BIND-DYNAMIC-CALLEE',
		'unit.check.PreferBindCheckTest#testUndeclaredBareCalleeNotFlagged :: control :: M-BIND-UNDECLARED-BARE',
		'unit.check.PreferCaseGuardCheckTest#testInScopeEnumNotFlagged :: control :: M-DECLARINGFILES-EMPTY',
		'unit.check.PreferComprehensionIndexFillTest#testACommentInsideTheInnerDeclarationRefusesTheNest :: control :: '
			+ 'M-COMPR-NESTED-DECL-COMMENT',
		'unit.check.PreferComprehensionIndexFillTest#testAHoistThatWouldWeldTwoCommentsIsRefused :: control :: M-COMPR-WELD-BLIND',
		'unit.check.PreferComprehensionIndexFillTest#testANestedBuildFolds :: control :: M-COMPR-NESTED-NEVER',
		'unit.check.PreferComprehensionIndexFillTest#testAnArrayTouchedBeforeTheLoopIsRefused :: control :: M-COMPR-GAP-NAME-BLIND',
		'unit.check.PreferComprehensionIndexFillTest#testAnExtraStatementInTheOuterBodyIsRefused :: control :: M-COMPR-NESTED-ANY-LENGTH',
		'unit.check.PreferComprehensionIndexFillTest#testAnIndexFillBoundedByTheArrayIsRefused :: control :: '
			+ 'M-COMPR-INDEXFILL-RANGE-UNCHECKED',
		'unit.check.PreferComprehensionIndexFillTest#testAnIndexFillFolds :: control :: M-COMPR-INDEXFILL-NEVER',
		'unit.check.PreferComprehensionIndexFillTest#testAnIndexFillFromANonZeroStartIsRefused :: control :: M-COMPR-INDEXFILL-ANY-START',
		'unit.check.PreferComprehensionIndexFillTest#testAnIndexFillIntoANonArrayIsRefused :: control :: M-COMPR-INDEXFILL-ANY-CONTAINER',
		'unit.check.PreferComprehensionIndexFillTest#testAnIndexFillReadingTheArrayIsRefused :: control :: '
			+ 'M-COMPR-INDEXFILL-VALUE-UNCHECKED',
		'unit.check.PreferComprehensionIndexFillTest#testAnIndexOtherThanTheBinderIsRefused :: control :: M-COMPR-INDEXFILL-ANY-INDEX',
		'unit.check.PreferComprehensionIndexFillTest#testAnInnerAnnotationTheOuterDoesNotRestateIsAscribed :: control :: '
			+ 'M-COMPR-NESTED-ASCRIPTION-DROPPED',
		'unit.check.PreferComprehensionIndexFillTest#testAnInnerFillReadingTheInnerArrayIsRefused :: control :: '
			+ 'M-COMPR-NESTED-INNER-UNCHECKED',
		'unit.check.PreferComprehensionIndexFillTest#testAnInnerFillReadingTheOuterArrayIsRefused :: control :: '
			+ 'M-COMPR-NESTED-CHECKS-UNMERGED',
		'unit.check.PreferComprehensionIndexFillTest#testAnOuterPushOfSomethingElseIsRefused :: control :: M-COMPR-NESTED-PUSH-ANY',
		'unit.check.PreferComprehensionIndexFillTest#testAnOwnLineCommentBetweenTheDeclarationAndTheLoopIsHoisted :: control :: '
			+ 'M-COMPR-GAP-COMMENT-DROPPED',
		'unit.check.PreferCountCheckTest#testFilteredFixFoldsDeclarationAndLoopAndInsertsUsing :: control :: M-SHADOWEXT-TRUE',
		'unit.check.PreferEnumAbstractCheckTest#testFixRefusalFollowsTheDeclarationNotTheSimpleName :: control :: '
			+ 'M-SUBTYPE-KEY-SIMPLE-NAME',
		'unit.check.PreferEnumAbstractCheckTest#testFixRefusesSubtypedContainer :: control :: M-HASSUBTYPE-FALSE',
		'unit.check.PreferFinalAbstractMethodCheckTest#testAbstractFieldNoCallStillFlagged :: control :: M-PFF-CALLSCAN-ALWAYS',
		'unit.check.PreferFinalAbstractMethodCheckTest#testClassTypedFieldMethodCallStillFlagged :: control :: M-PFF-REBIND-UNRESOLVED',
		'unit.check.PreferFinalAbstractMethodCheckTest#testCtorOnlyAbstractFieldFlagged :: control :: M-PFF-REBIND-UNRESOLVED',
		'unit.check.PreferFinalAbstractMethodCheckTest#testCtorOnlyAbstractLocalFlagged :: control :: M-PFF-REBIND-UNRESOLVED',
		'unit.check.PreferFinalAbstractMethodCheckTest#testForwardToAliasedUnderlyingWhitelistedNameFlagged :: control :: '
			+ 'M-PFF-STDLIB-SAFE-NONE',
		'unit.check.PreferFinalAbstractMethodCheckTest#testForwardToAliasedUnderlyingWhitelistedNameLocalFlagged :: control :: '
			+ 'M-PFF-STDLIB-SAFE-NONE',
		'unit.check.PreferFinalAbstractMethodCheckTest#testForwardToClassAbstractFieldFlagged :: control :: M-PFF-REBIND-UNRESOLVED',
		'unit.check.PreferFinalAbstractMethodCheckTest#testPlainFieldStillFlagged :: control :: M-PFF-CALLSCAN-ALWAYS',
		'unit.check.PreferFinalAbstractMethodCheckTest#testPlainLocalStillFlagged :: control :: M-PFF-CALLSCAN-ALWAYS',
		'unit.check.PreferFinalAbstractMethodCheckTest#testPrivateCtorOnlyNoMetaStillFlagged :: control :: M-PFF-REBIND-UNRESOLVED',
		'unit.check.PreferFinalAbstractMethodCheckTest#testResolutionScopeResolvesLibraryType :: control :: M-SCOPE-LIBRARY-DROPPED',
		'unit.check.PreferFinalAbstractMethodCheckTest#testStdlibArrayFieldMethodCallStillFlagged :: control :: M-PFF-STDLIB-SAFE-NONE',
		'unit.check.PreferFinalAbstractMethodCheckTest#testStdlibStringFieldMethodCallStillFlagged :: control :: M-PFF-STDLIB-SAFE-NONE',
		'unit.check.PreferFinalMacroOwnerTest#testABuilderReadingFinalityDeclinesEvenUnderTheOracle :: control :: '
			+ 'M-FINAL-MACRO-FINALITY-BLIND',
		'unit.check.PreferFinalMacroOwnerTest#testAPrivateFieldOfAMacroBuiltOwnerIsFixedUnderTheOracle :: control :: '
			+ 'M-PFF-MACRO-NEVER-ADMITTED',
		'unit.check.PreferFinalMacroOwnerTest#testAPrivateFieldOfAMacroBuiltOwnerIsNotFixedWithoutTheOracle :: control :: '
			+ 'M-PFF-MACRO-FIXED',
		'unit.check.PreferFinalMacroOwnerTest#testAPrivateFieldOfAMacroBuiltOwnerIsReportedAndDeclined :: control :: M-PFF-MACRO-SILENT',
		'unit.check.PreferFinalMacroOwnerTest#testAPublicFieldOfAMacroBuiltOwnerIsFixedUnderTheOracle :: control :: '
			+ 'M-PFPF-MACRO-NEVER-ADMITTED',
		'unit.check.PreferFinalMacroOwnerTest#testAPublicFieldOfAMacroBuiltOwnerIsNotFixedWithoutTheOracle :: control :: '
			+ 'M-PFPF-MACRO-FIXED',
		'unit.check.PreferFinalMacroOwnerTest#testAPublicFieldOfAMacroBuiltOwnerIsReportedAndDeclined :: control :: M-PFPF-MACRO-SILENT',
		'unit.check.PreferFinalMacroOwnerTest#testTheFoldIsNeverAdmittedOnAMacroBuiltOwner :: control :: M-FINAL-MACRO-FOLD-ADMITTED',
		'unit.check.PreferFindCheckTest#testFixRefusedWhenTheOnlyUsingIsGuarded :: control :: M-GUARDED-USING-ABSENT',
		'unit.check.PreferForeachCheckTest#testALaterUsingOfferingNoExtensionIsPassedOver :: control :: '
			+ 'M-EXT-DECL-PASS-OVER,M-EXT-DECL-STATIC,M-EXT-DECL-NOUSING',
		'unit.check.PreferForeachCheckTest#testALaterUsingThatMayOfferTheExtensionStopsTheWalk :: control :: '
			+ 'M-EXT-DECL-BUILT,M-EXT-DECL-GUARDED-HOST',
		'unit.check.PreferForeachCheckTest#testGuardedUsingOrDeclarationRefuses :: control :: '
			+ 'M-EXT-DECL-GUARDED-MEMBER,M-BINDER-EXTENSION-GUARDED-USING',
		'unit.check.PreferForeachCheckTest#testLaterUsingWinsOverEarlierOne :: control :: M-BINDER-EXTENSION-LAST-USING',
		'unit.check.PreferForeachCheckTest#testReceiverUsingMetaBeatsTheFileUsing :: control :: M-BINDER-EXTENSION-ATUSING',
		'unit.check.PreferForeachCheckTest#testTheCompilersUsingOrder :: control :: M-BINDER-EXTENSION-FIRST-PARAM,M-EXT-DECL-TWO-HOSTS,M-BINDER-EXTENSION-ATUSING,M-EXT-PRIVATE-OPEN,M-EXT-MODULE-FIELDS-OPEN',
		'unit.check.PreferForeachCheckTest#testTwoTypesOfOneModuleDeclaringTheNameRefuse :: control :: M-EXT-DECL-TWO-HOSTS',
		'unit.check.PreferForeachCheckTest#testUnindexedLaterUsingStopsTheWalk :: control :: M-USING-HOSTS-ALIAS',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainElseWhileNotFlagged :: control :: M-ELSELESS-FINAL-ELSE',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainImpureInitNotFlagged :: control :: M-DECLCHAIN-INIT-ANY',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainNestedWriteNotFlagged :: control :: M-DECLCHAIN-OCCURRENCE-COUNT',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainNotAdjacentNotFlagged :: control :: M-DECLIF-CARRY',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainOtherTargetNotFlagged :: control :: M-DECLCHAIN-LVALUE',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainPrefixComments :: control :: '
			+ 'M-DECLIF-PREFIX-KEPT,M-DECLCHAIN-PREFIX-DANGLING',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainTargetReadNotFlagged :: control :: M-DECLCHAIN-OCCURRENCE-COUNT',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclChainUntypedNotFlagged :: control :: M-DECLCHAIN-UNTYPED',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testDeclElseLessChainFolded :: control :: M-DECLCHAIN-OWNED-BY-TERNARY',
		'unit.check.PreferIfExpressionAssignmentCheckTest#testFlatTwoBranchStillNotFlagged :: control :: M-TERMINAL-RUNGS-ANY',
		'unit.check.PreferIfExpressionChainCheckTest#testBooleanReducibleUnfoldedRungStillConverts :: control :: M-PIEC-SPINE-CLAIM-ANY',
		'unit.check.PreferIfExpressionChainCheckTest#testChainWithNoBooleanLeafStillFlagged :: control :: M-PIEC-SPINE-CLAIM-ANY',
		'unit.check.PreferIfExpressionReturnCheckTest#testFallThroughCascadeClaimedNotRewritten :: control :: M-PIER-CASCADE-UNMERGED-REPORTED',
		'unit.check.PreferIfExpressionReturnCheckTest#testGuardBeforeTernaryClaimedNotRewritten :: control :: M-PIER-CASCADE-UNMERGED-REPORTED',
		'unit.check.PreferIfExpressionReturnCheckTest#testGuardLadderIsNotMerged :: control :: M-PIER-TAIL-LADDER',
		'unit.check.PreferIfExpressionReturnCheckTest#testGuardRepeatingTheTernaryElseMerges :: control :: M-PIER-OUTER-UNNEGATED,M-PIER-MERGE-NO-PARENS',
		'unit.check.PreferIfExpressionReturnCheckTest#testMergeRefusals :: control :: M-PIER-MERGE-ANY-VALUE,M-PIER-MERGE-COMMENT',
		'unit.check.PreferIfExpressionReturnCheckTest#testRepeatedLeadingValueMergesByOr :: control :: M-PIER-LEADING-AS-OUTER',
		'unit.check.PreferIfExpressionReturnCheckTest#testStatementLikeValueIsNotMerged :: control :: M-PIER-MERGE-UNMARCHABLE',
		'unit.check.PreferIfExpressionReturnCheckTest#testTailMergeRefusals :: control :: M-PIER-TAIL-FROM-FOLDED',
		'unit.check.PreferIfExpressionReturnCheckTest#testTailOfALongerCascadeMerges :: control :: M-PIER-MERGE-ANY-COUNT,M-PIER-TAIL-SPAN-WHOLE,M-PIER-TAIL-REPORTED-AT-HEAD',
		'unit.check.PreferIfExpressionReturnCheckTest#testTailRepeatingLeadingValueMergesByOr :: control :: M-PIER-MERGE-ANY-COUNT',
		'unit.check.PreferIfExpressionReturnCheckTest#testTwoWrittenBranchesAndAFoldedTailAreNotAChain :: control :: M-PIER-REWRITES-FOLDED,M-PIER-CLAIMSCHAIN-OWNS',
		'unit.check.PreferIndexAccessCheckTest#testObjectLiteralSetValueNotFlagged :: control :: M-PIA-OBJLIT-SET-FLAGGED',
		'unit.check.PreferInlineCheckTest#testOwnFileBuildMacroTokenCostsNoResolutionIndex :: control :: M-INLINE-LOCAL-BUILD-MACRO',
		'unit.check.PreferInlineCheckTest#testQualifiedSupertypeKeySplitsTheTwinFromTheRealSubtypesOwner :: control :: '
			+ 'M-INLINE-SUBTYPE-REPORT-INDEX',
		'unit.check.PreferInlineCheckTest#testSubtypeExtendingThroughALaterBranchSkips :: control :: M-SUPERTYPES-FIRST-WRITTEN-ONLY',
		'unit.check.PreferInterpolationCheckTest#testConstantAfterAShorthandReadBracesTheRead :: control :: '
			+ 'M-INTERP-CONSTANT-BLOCK-IGNORED',
		'unit.check.PreferInterpolationCheckTest#testEveryInterpolatedConstantKindBecomesItsPrintedText :: control :: '
			+ 'M-CONSTANT-NEGATIVE-ZERO-SIGNED',
		'unit.check.PreferInterpolationCheckTest#testInterpolatedConstantBecomesText :: control :: '
			+ 'M-FOLD-CONSTANT-AS-EXPRESSION,M-INTERP-CONSTANT-BLOCK-IGNORED',
		'unit.check.PreferInterpolationCheckTest#testInterpolatedConstantInAnnotationNotFlagged :: control :: M-INTERP-CONSTANT-IN-META',
		'unit.check.PreferInterpolationCheckTest#testMacroArgumentIsReportedButNotFixed :: control :: M-INTERP-MACRO-ARGUMENT-REWRITTEN',
		'unit.check.PreferInterpolationCheckTest#testTargetDependentConstantsKeepTheirBlock :: control :: '
			+ 'M-CONSTANT-DECIMAL-RANGE-UNCHECKED,M-CONSTANT-FLOAT-ADMITTED,M-CONSTANT-HEX-RANGE-UNCHECKED',
		'unit.check.PreferInterpolationCheckTest#testTypedefOfNullArgumentNotFlagged :: control :: M-INTERP-NULLITY-SKIPPED',
		'unit.check.PreferKeyValueLoopCheckTest#testASiblingLoopsBinderIsNoClash :: control :: M-REACH-UNDECLARED-BUILTIN',
		'unit.check.PreferKeyValueLoopCheckTest#testConstructorCallIsReportOnly :: control :: M-ELEMENT-LOOP-NEW-EXPR',
		'unit.check.PreferKeyValueLoopCheckTest#testIndexOnlyLoopLeftToValueLoop :: control :: M-KV-NOOPENER-INDEX-ONLY',
		'unit.check.PreferKeyValueLoopCheckTest#testNestedBinderClashAcrossTheTwoRules :: control :: M-ELEMENT-LOOP-NESTED-BINDER',
		'unit.check.PreferKeyValueLoopCheckTest#testNestedLoopsDerivingOneBinderAreReportOnly :: control :: M-ELEMENT-LOOP-NESTED-BINDER',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerBinderTakenByFieldIsReportOnly :: control :: M-KV-NOOPENER-TAKEN-MEMBER',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerBinderTakenInFunctionIsReportOnly :: control :: M-KV-NOOPENER-TAKEN-SCOPE',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerClosureReadNotFlagged :: control :: '
			+ 'M-ELEMENT-LOOP-CLOSURE,M-KV-NOOPENER-BODY-GATES',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerFieldLoopRewritten :: control :: '
			+ 'M-ELEMENT-LOOP-UNDERSCORE,M-VALUE-LOOP-READS-UNSPLICED',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerIndexWriteNotFlagged :: control :: M-KV-NOOPENER-INDEX-WRITE',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerLengthChangeNotFlagged :: control :: M-ELEMENT-LOOP-UNSTABLE',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerNonArrayNotFlagged :: control :: M-KV-NOOPENER-NON-ARRAY',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerSelfCallIsReportOnly :: control :: M-KV-NOOPENER-SELF-CALL',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerShadowedIndexNotFlagged :: control :: M-ELEMENT-LOOP-REBIND',
		'unit.check.PreferKeyValueLoopCheckTest#testNoOpenerSlotWriteNotFlagged :: control :: M-ELEMENT-LOOP-UNSTABLE',
		'unit.check.PreferKeyValueLoopCheckTest#testOpenerSelfCallIsReportOnly :: control :: M-KV-OPENER-SELF-CALL',
		'unit.check.PreferKeyValueLoopCheckTest#testOpenerWithSecondReadStaysUnclaimed :: control :: M-KV-NOOPENER-OPENER-CLAIM',
		'unit.check.PreferKeyValueLoopCheckTest#testSetterRunByTheBodyIsFollowed :: control :: M-GRAPH-SETTER-EDGE',
		'unit.check.PreferKeyValueLoopCheckTest#testStaticCallOnATypeIsReportOnly :: control :: M-ELEMENT-LOOP-TYPE-CALLEE',
		'unit.check.PreferKeyValueLoopCheckTest#testThisQualifiedCollectionNotFlagged :: control :: M-ELEMENT-LOOP-REBIND',
		'unit.check.PreferLocalFunctionCheckTest#testDeclaredResultIsCarried :: control :: M-LOCALFN-RESULT-DROPPED',
		'unit.check.PreferLocalFunctionCheckTest#testLiteralReadingItsOwnNameRefused :: control :: M-LOCALFN-OUTER-NAME-READ',
		'unit.check.PreferLocalFunctionCheckTest#testSignatureMismatchRefused :: control :: M-LOCALFN-SIGNATURE-ANY',
		'unit.check.PreferLocalFunctionCheckTest#testVoidExpressionBodyIsWrapped :: control :: M-LOCALFN-VOID-RETURNED',
		'unit.check.PreferLocalFunctionCheckTest#testWhileExpressionPositionRefused :: control :: M-VOCAB-WHILE-EXPR-NOT-BRANCH',
		'unit.check.PreferNullCoalescingCheckTest#testNullFallbackIsTheGuardedValue :: control :: M-NULLCOAL-NULL-FALLBACK',
		'unit.check.PreferStaticExtensionCheckTest#testGuardedImportRunGetsNoSecondUsing :: control :: M-GUARDED-USING-ABSENT',
		'unit.check.PreferStaticExtensionCheckTest#testGuardedImportRunRefusalNamesTheRegion :: control :: M-GUARDED-USING-ABSENT',
		'unit.check.PreferStaticExtensionCheckTest#testMessageKeepsATwoSpaceLiteral :: control :: M-RENDER-SPAN-TOKENS',
		'unit.check.PreferStaticExtensionCheckTest#testMessageQuotesLiteralWhitespaceExactlyAsTheFixWritesIt :: control :: '
			+ 'M-RENDER-SPAN-TOKENS',
		'unit.check.PreferStaticExtensionCheckTest#testUsingInAnotherBranchDoesNotCoverTheCall :: control :: M-COND-BRANCH-SPAN-SHARED',
		'unit.check.PreferStaticExtensionFactsTest#testABinderALaterCallMayHaveTypedIsNotRewritten :: control :: '
			+ 'M-FACTS-CLOSED-PARAMETER,M-FACTS-FIXED-ANY-BINDER,M-FACTS-FIXED-LOOP-ANY,M-FACTS-CTOR-EVERY',
		'unit.check.PreferStaticExtensionFactsTest#testABinderTheCompilerTypedWhenItBoundItIsRewritten :: control :: '
			+ 'M-FACTS-FIXED-CAPTURE,M-FACTS-FIXED-LOOP,M-FACTS-CTOR-ARITY',
		'unit.check.PreferStaticExtensionFactsTest#testAConditionalUsingProvidingTheMethodDropsTheSite :: control :: '
			+ 'M-PSE-CHANNEL-REGION-USING',
		'unit.check.PreferStaticExtensionFactsTest#testADynamicReceiverIsDropped :: control :: M-PSE-FACTS-DYNAMIC',
		'unit.check.PreferStaticExtensionFactsTest#testAForwardingAbstractIsNoMemberHost :: control :: M-PSE-FACTS-HOSTS',
		'unit.check.PreferStaticExtensionFactsTest#testAMemberOfASupertypeOrAnInterfaceDropsTheSite :: control :: M-PSE-FACTS-SHADOW',
		'unit.check.PreferStaticExtensionFactsTest#testANoUsingFunctionDropsTheSite :: control :: M-PSE-CHANNEL-NO-USING',
		'unit.check.PreferStaticExtensionFactsTest#testAReceiverOnlyTheFactsTypeIsRewritten :: control :: M-PSE-FACTS-OFF,M-PSE-FACTS-NULL',
		'unit.check.PreferStaticExtensionFactsTest#testAReceiverTwoConfigurationsTypeDifferentlyIsNotRewritten :: guard :: ',
		'unit.check.PreferStaticExtensionFactsTest#testAReceiverWhoseTypeTheCallMayHaveInferredIsNotRewritten :: control :: '
			+ 'M-PSE-FACTS-INFERRED',
		'unit.check.PreferStaticExtensionFactsTest#testATypeWithItsOwnUsingIsNotRewritten :: control :: M-PSE-FACTS-USING',
		'unit.check.PreferStaticExtensionFactsTest#testAUsingOfAModuleFollowsItsTypedefs :: control :: M-PSE-USING-ALIAS-HOST',
		'unit.check.PreferStaticExtensionFactsTest#testAUsingOfAModuleWeighsEveryTypeItDeclares :: control :: M-PSE-USING-MODULE-WIDE',
		'unit.check.PreferStaticExtensionFactsTest#testAUsingOnASupertypeKeepsTheSiteReportOnly :: control :: M-PSE-CLOSURE-USING-SUPER',
		'unit.check.PreferStaticExtensionFactsTest#testAUsingOnTheReceiverTypeKeepsTheSiteReportOnly :: control :: M-PSE-CLOSURE-USING',
		'unit.check.PreferStaticExtensionFactsTest#testAnAbstractParameterIsNotRewritten :: control :: M-PSE-FACTS-PARAM',
		'unit.check.PreferStaticExtensionFactsTest#testAnImportAliasOfTheModuleNameDropsTheSite :: control :: M-PSE-CHANNEL-ALIAS',
		'unit.check.PreferStaticExtensionFactsTest#testAnOverloadIsNotRewritten :: control :: M-PSE-FACTS-OVERLOAD',
		'unit.check.PreferStaticExtensionFactsTest#testFactsOfAnotherTextProveNothing :: control :: M-PSE-FACTS-TEXT',
		'unit.check.PreferStaticExtensionFactsTest#testTheConfiguredModulesOwnNeighboursDropTheSite :: control :: M-PSE-USING-SELF-MODULE',
		'unit.check.PreferStaticExtensionFactsTest#testTheFactsWeighEveryTypeAUsedModuleDeclares :: control :: '
			+ 'M-PSE-FACTS-USING-MODULE-WIDE',
		'unit.check.PreferStaticExtensionFactsTest#testTheFactsWeighTheConfiguredModulesNeighbours :: control :: '
			+ 'M-PSE-FACTS-USING-SELF-MODULE',
		'unit.check.PreferStaticExtensionFactsTest#testTheFirstParameterOfAFactsSignature :: control :: M-PSE-FIRST-PARAM',
		'unit.check.PreferStaticExtensionFactsTest#testTheRewrittenBindersPrintWhatTheyPrinted :: guard :: ',
		'unit.check.PreferStaticExtensionFactsTest#testTheRewrittenProgramPrintsWhatItPrinted :: guard :: ',
		'unit.check.PreferSwitchCheckTest#testBareBranchBodiesGainATerminator :: control :: M-SWITCH-BARE-BODY-VERBATIM',
		'unit.check.PreferSwitchCheckTest#testDuplicateValueAcrossSpellingsNotFlagged :: control :: M-SWITCH-VALUES-NOT-DISTINCT',
		'unit.check.PreferSwitchCheckTest#testElselessBracelessBodyNotFlagged :: control :: M-SWITCH-ELSELESS-ANY-HOST',
		'unit.check.PreferSwitchCheckTest#testElselessEnumAbstractChainFixed :: control :: M-SWITCH-ELSELESS-REFUSED',
		'unit.check.PreferSwitchCheckTest#testElselessLastInNestedBlockNotFlagged :: control :: M-SWITCH-ELSELESS-LAST-IN-VALUE-BLOCK',
		'unit.check.PreferSwitchCheckTest#testEnumAbstractDuplicateValueNotFlagged :: control :: M-SWITCH-VALUES-NOT-DISTINCT',
		'unit.check.PreferSwitchCheckTest#testGuardedTrailingElseNotFlagged :: control :: M-SWITCH-ELSELESS-GUARDED-ELSE',
		'unit.check.PreferSwitchCheckTest#testImplicitEnumAbstractValues :: control :: '
			+ 'M-CASEVALUE-IMPLICIT-NOT-COUNTED,M-CASEVALUE-NAMING-UNKNOWN',
		'unit.check.PreferSwitchCheckTest#testNoTrailingElseClosesWithAnEmptyWildcard :: control :: M-SWITCH-ELSELESS-REFUSED',
		'unit.check.PreferSwitchCheckTest#testOverloadedEqualityDiscriminantNotFlagged :: control :: M-SWITCH-DISC-EQ-OVERLOAD-IGNORED',
		'unit.check.PreferSwitchCheckTest#testOverloadedEqualityPatternNotFlagged :: control :: M-SWITCH-PATTERN-EQ-OVERLOAD-IGNORED',
		'unit.check.PreferSwitchCheckTest#testReportScopedFixIndexStillResolvesTheConstant :: control :: M-SWITCH-FIX-REPORT-INDEX-FIRST',
		'unit.check.PreferSwitchCheckTest#testTerminatedBranchBodiesAreNotDoubled :: control :: M-SWITCH-TERMINATED-BODY-DOUBLED',
		'unit.check.PreferSwitchCheckTest#testUnknownConstantValueNotFlagged :: control :: M-SWITCH-UNKNOWN-VALUE-ACCEPTED',
		'unit.check.PreferSwitchCheckTest#testValueChainInALambdaBlockGainsTerminators :: control :: M-SWITCH-BARE-BODY-VERBATIM',
		'unit.check.PreferSwitchExpressionCheckTest#testSharedValueAndOperatorGates :: control :: M-SWITCH-VALUES-NOT-DISTINCT',
		'unit.check.PreferTernaryAssignmentCheckTest#testDeclDroppedCommentNotFlagged :: control :: M-DECLTERN-COMMENT',
		'unit.check.PreferTernaryAssignmentCheckTest#testDeclNegatedConditionEmitsPositiveTernary :: control :: M-PTA-NO-ORIENT',
		'unit.check.PreferTernaryAssignmentCheckTest#testDeclNullNarrowingBoolNotFlagged :: control :: M-DECLTERN-NARROWING',
		'unit.check.PreferTernaryAssignmentCheckTest#testDeclNullPassThroughWritesTheValue :: control :: M-PASSTHROUGH-TERNARY',
		'unit.check.PreferTernaryAssignmentCheckTest#testKeepDefaultElseKeepsTheNegatedAssignment :: control :: '
			+ 'M-NEGCOND-KEEP-DEFAULT-BLIND,M-NEGCOND-KEEP-DEFAULT-THEN-ARM',
		'unit.check.PreferTernaryAssignmentCheckTest#testMutatingPassThroughKeepsTheTernary :: control :: M-NULLPASS-MUTATES',
		'unit.check.PreferTernaryAssignmentCheckTest#testNegatedConditionEmitsPositiveTernary :: control :: '
			+ 'M-PTA-NO-ORIENT,M-NEGCOND-SWAP-OFF',
		'unit.check.PreferTernaryAssignmentCheckTest#testNullPassThroughAssignmentWritesTheValue :: control :: M-PASSTHROUGH-TERNARY',
		'unit.check.PreferTernaryExpressionCheckTest#testKeepDefaultElseKeepsTheNegatedIfExpression :: control :: '
			+ 'M-NEGCOND-KEEP-DEFAULT-BLIND,M-NEGCOND-KEEP-DEFAULT-THEN-ARM',
		'unit.check.PreferTernaryExpressionCheckTest#testNegatedConditionEmitsPositiveTernary :: control :: '
			+ 'M-PTE-NO-ORIENT,M-NEGCOND-SWAP-OFF',
		'unit.check.PreferTernaryReturnCheckTest#testKeepDefaultElseKeepsTheNegatedGuard :: control :: '
			+ 'M-NEGCOND-KEEP-DEFAULT-BLIND,M-PTR-KEEP-DEFAULT-THEN-ARM',
		'unit.check.PreferTernaryReturnCheckTest#testNegatedGuardEmitsPositiveTernary :: control :: M-PTR-NO-ORIENT',
		'unit.check.PreferTernaryReturnCheckTest#testNegatedGuardTrailingCommentKeepsNegation :: control :: M-PTR-TRAILING-SWAPS',
		'unit.check.PreferTernaryReturnCheckTest#testOwnLineCommentInACascadeDefersTheTail :: control :: '
			+ 'M-PTR-RIDES-NEVER,M-PTR-CASCADE-NEVER-STRANDS',
		'unit.check.PreferTernaryReturnCheckTest#testTheRunOfOneHoistIsRefusedAtTheSeam :: control :: M-COMMENT-HOIST-BLIND',
		'unit.check.PreferValueLoopCheckTest#testBodyThatMayChangeTheCollectionIsReportOnly :: control :: M-VALUE-LOOP-SELF-CALL',
		'unit.check.PreferValueLoopCheckTest#testClosureReadNotFlagged :: control :: M-ELEMENT-LOOP-CLOSURE,M-VALUE-LOOP-BODY-GATES',
		'unit.check.PreferValueLoopCheckTest#testFixRewritesBlockBody :: control :: M-VALUE-LOOP-READS-UNSPLICED',
		'unit.check.PreferValueLoopCheckTest#testInnerPluralWordNamesTheBinder :: control :: M-SINGULAR-INNER-WORD',
		'unit.check.PreferValueLoopCheckTest#testMacroIndexReadNotFlagged :: control :: M-VALUE-LOOP-INDEX-TEXT-BLIND',
		'unit.check.PreferValueLoopCheckTest#testMethodOfAnotherObjectHoldingTheCollectionIsReportOnly :: control :: '
			+ 'M-REACH-ESCAPE-ARGUMENT',
		'unit.check.PreferValueLoopCheckTest#testNestedLoopsDerivingOneBinderAreReportOnly :: control :: M-ELEMENT-LOOP-NESTED-BINDER',
		'unit.check.PreferValueLoopCheckTest#testPrivateFieldCollectionDropsItsUnderscore :: control :: M-ELEMENT-LOOP-UNDERSCORE',
		'unit.check.PreferValueLoopCheckTest#testSingularOfReadsTheLastPluralWord :: control :: '
			+ 'M-SINGULAR-INNER-WORD,M-SINGULAR-WORD-END-ANYWHERE',
		'unit.check.PreferValueLoopCheckTest#testStaticAndConstructorCallsThatGrowTheCollectionAreReportOnly :: control :: '
			+ 'M-ELEMENT-LOOP-TYPE-CALLEE,M-ELEMENT-LOOP-NEW-EXPR',
		'unit.check.PreferValueLoopCheckTest#testThisQualifiedCollectionNotFlagged :: control :: M-ELEMENT-LOOP-REBIND',
		'unit.check.ReachBuildsCacheTest#testABuildThatReadAnUnhashedFileIsNotStored :: control :: M-REACH-HASHED-UNCHECKED',
		'unit.check.ReachBuildsCacheTest#testAGenerationNoLongerCurrentIsNotReadFromTheStore :: control :: M-REACH-GENERATION-UNCHECKED',
		'unit.check.ReachBuildsCacheTest#testAMisshapenRecordIsAMiss :: control :: M-REACH-RECORD-SHAPE-UNCHECKED',
		'unit.check.ReachBuildsCacheTest#testANoOracleRunReadsTheBuildsAnOracleRunStored :: control :: M-REACH-STORED-UNREAD,M-REACH-STORE-OFF',
		'unit.check.ReachBuildsCacheTest#testAReadTheFingerprintCannotSeeIsNeitherStoredNorRead :: control :: M-REACH-HASHED-UNCHECKED,M-REACH-LIBRARY-UNCHECKED',
		'unit.check.ReachBuildsCacheTest#testAVerdictWhoseCompileReadAnUnhashedFileIsNotStored :: control :: M-ORACLE-VERDICT-READS-UNCHECKED',
		'unit.check.ReachBuildsCacheTest#testAnEditedInputIsNotReadFromTheStore :: control :: M-REACH-KEY-UNCHECKED',
		'unit.check.ReachDefinesProbeTest#testADefineAnInitializationMacroSetsIsNotDefinedForEveryFile :: control :: M-DEFINES-EARLY',
		'unit.check.ReachDefinesProbeTest#testAValueIsTheDefinesWhereTheFirstAndLastSetsAgree :: control :: M-DEFINES-VALUES-STABLE',
		'unit.check.ReachDefinesProbeTest#testBuildsStartedAheadAnswerOnlyAQuestionBeforeTheFirstWrite :: control :: '
			+ 'M-AHEAD-NEVER-READ,M-AHEAD-READ-AFTER-WRITE',
		'unit.check.ReachDefinesProbeTest#testEveryTypedTypeIsReportedWithItsFile :: control :: M-DEFINES-TYPES,M-DEFINES-IMPL',
		'unit.check.ReachDefinesProbeTest#testOnlyAOneArmTranscriptWithBothSetsAnswers :: control :: M-DEFINES-ONE-ARM',
		'unit.check.ReachDefinesProbeTest#testOverlappingProbesAnswerInTheOraclesOrder :: control :: M-SPAWN-ORDER',
		'unit.check.ReachDefinesProbeTest#testTheBuildsStartBesideFactsStartedEarly :: control :: M-BUILDS-WITH-FACTS',
		'unit.check.ReachDefinesProbeTest#testTheProbeNamesEveryFileTheBuildParses :: control :: M-DEFINES-PARSED-DROPPED',
		'unit.check.ReachDefinesProbeTest#testTheProbeReadsTheValueEachDefineCarries :: control :: M-DEFINES-VALUES-MACRO',
		'unit.check.RedundantImportCheckTest#testAThirdLineBindingOneOfItsConstructorsKeepsIt :: control :: M-REDUNDANT-VALUES-BLIND',
		'unit.check.RedundantImportCheckTest#testSubTypeImportBesideItsModuleImportIsRedundant :: control :: M-DECLARINGFILES-EMPTY',
		'unit.check.RedundantIsVarCheckTest#testBypassAccessorNotFlagged :: control :: M-ISVAR-BYPASS-BLIND',
		'unit.check.RedundantIsVarCheckTest#testCppCodeOutsideAnAccessorNotFlagged :: control :: M-ISVAR-NATIVE-BLIND',
		'unit.check.RedundantIsVarCheckTest#testDefaultSlotNotFlagged :: control :: M-ISVAR-SLOTS-ANY',
		'unit.check.RedundantIsVarCheckTest#testEmptyArgumentListIsFixedAndArgumentsAreNotJudged :: control :: M-ISVAR-EMPTY-CALL-UNFIXED',
		'unit.check.RedundantIsVarCheckTest#testFunctionCodeMetaNotFlagged :: control :: M-ISVAR-NATIVE-BLIND',
		'unit.check.RedundantIsVarCheckTest#testGetterReadingStorageNotFlagged :: control :: M-ISVAR-ACCESSOR-BODY-BLIND',
		'unit.check.RedundantIsVarCheckTest#testInitializerNotFlagged :: control :: M-ISVAR-INIT-BLIND',
		'unit.check.RedundantIsVarCheckTest#testJsSyntaxCodeOutsideAnAccessorNotFlagged :: control :: M-ISVAR-NATIVE-BLIND',
		'unit.check.RedundantIsVarCheckTest#testKeptMemberNotFlagged :: control :: M-ISVAR-MEMBER-KEEP-BLIND',
		'unit.check.RedundantIsVarCheckTest#testMacroBuiltOwnerDeclinedWithoutTheOracle :: control :: M-ISVAR-MACRO-FIXED',
		'unit.check.RedundantIsVarCheckTest#testMacroBuiltOwnerFixedUnderTheOracle :: control :: M-ISVAR-MACRO-NEVER-ADMITTED',
		'unit.check.RedundantIsVarCheckTest#testOpaqueCondRegionMentioningTheNameNotFlagged :: control :: M-ISVAR-OPAQUE-BLIND',
		'unit.check.RedundantIsVarCheckTest#testReflectionByNameNotFlagged :: control :: M-ISVAR-REFLECTION-BLIND',
		'unit.check.RedundantIsVarCheckTest#testRttiOwnerNotFlagged :: control :: M-ISVAR-RTTI-BLIND',
		'unit.check.RedundantIsVarCheckTest#testSetterWritingStorageNotFlagged :: control :: M-ISVAR-ACCESSOR-BODY-BLIND',
		'unit.check.RedundantIsVarCheckTest#testSubclassOverrideOutsideTheReportScopeNotFlagged :: control :: M-ISVAR-SCOPE-REPORT-ONLY',
		'unit.check.RedundantIsVarCheckTest#testSubclassOverrideWritingStorageNotFlagged :: control :: M-ISVAR-ACCESSOR-BODY-BLIND',
		'unit.check.RedundantIsVarCheckTest#testUnresolvedSupertypeNotFlagged :: control :: M-ISVAR-CHAIN-UNRESOLVED-ADMITTED',
		'unit.check.RedundantLambdaWrapperCheckTest#testLocalFunctionFlagged :: control :: M-RLW-LOCAL-FN-AS-BINDER',
		'unit.check.RedundantLambdaWrapperCheckTest#testNamedFunctionLiteralShadowsAMemberCallee :: control :: M-RLW-NAMED-FN-NOT-BINDER',
		'unit.check.RedundantMapIterKeyCheckTest#testFixDeclinedOverANonStandardMap :: control :: M-MAPITER-SUBTYPE-VETO-OFF',
		'unit.check.RedundantMapIterKeyCheckTest#testFixDeclinedOverAliasedList :: control :: M-ULB-IMPORT-ALIAS-BLIND',
		'unit.check.RedundantMapIterKeyCheckTest#testFixDeclinedOverMapAndUnknownIterable :: control :: M-MAPITERKEY-UNPROVEN-DROPPED',
		'unit.check.RedundantMapIterKeyCheckTest#testFixDeclinedOverReassignedLocal :: control :: M-ULB-REASSIGNED-LOCAL-BLIND',
		'unit.check.RedundantMapIterKeyCheckTest#testFixDeclinedWhereTheBodyChangesALocalMap :: control :: '
			+ 'M-MAPITER-REACH-SKIPPED,M-REACH-LOCAL-TOUCH-BLIND',
		'unit.check.RedundantMapIterKeyCheckTest#testFixDropsKeyOverALocalMapTheLoopLeavesUnchanged :: control :: '
			+ 'M-MAPITER-KEYED-NEVER,M-TOUCH-NEW-MAP-NOT-FRESH',
		'unit.check.RedundantMapIterKeyCheckTest#testMessageRecommendsTheDropOnlyWhenProved :: control :: '
			+ 'M-MAPITERKEY-MESSAGE-ALWAYS-PROVEN',
		'unit.check.RedundantNullCoalescingCheckTest#testNullRightOperandUnwraps :: control :: M-REDUNDANT-COAL-NULL-RIGHT',
		'unit.check.RedundantNullCoalescingCheckTest#testTypedefOfNullLeftNotFlagged :: control :: M-PROVER-NULLITY-SKIPPED',
		'unit.check.RedundantNullCoalescingCheckTest#testValueTypeFieldWithInitialiserFlagged :: control :: M-VALUE-TYPE-FIELDS-REFUSED',
		'unit.check.RedundantNullCoalescingCheckTest#testValueTypeFieldWithoutInitialiserNotFlagged :: control :: '
			+ 'M-VALUE-TYPE-UNINIT-FIELD',
		'unit.check.RedundantNullCoalescingCheckTest#testValueTypePropertyReadThroughGetterFlagged :: control :: '
			+ 'M-VALUE-TYPE-FIELDS-REFUSED',
		'unit.check.RedundantParensCheckTest#testDoubleParensAroundASpliceCollapseToOnePair :: control :: M-PARENS-QUOTED-DROPPED',
		'unit.check.RedundantParensCheckTest#testSpliceReificationKeepsItsParensInASplicingHost :: control :: M-PARENS-SPLICE-HOST-OPEN',
		'unit.check.RedundantParensCheckTest#testSpliceReificationOutsideASplicingHostIsUnwrapped :: control :: M-PARENS-QUOTED-DROPPED',
		'unit.check.RedundantParensOperandArmsTest#testMacroQuotationSubtreeIsUntouched :: control :: M-PARENS-OPERAND-QUOTED-OPEN',
		'unit.check.RedundantReplaceLoopCheckTest#testEmptyLiteralReplacementBoundsTheRedundancyToOneCharacter :: control :: '
			+ 'M-EMPTY-B-ANY-NONEMPTY',
		'unit.check.RedundantReplaceLoopCheckTest#testMultiCharSearchWithEmptyReplacementNotFlagged :: control :: M-SEAM-BLIND',
		'unit.check.RedundantReplaceLoopCheckTest#testReplacementInsideSearchNotFlagged :: control :: M-SEAM-BLIND',
		'unit.check.RedundantReplaceLoopCheckTest#testSeamReformingLiteralPairNotFlagged :: control :: M-SEAM-BLIND',
		'unit.check.RedundantReplaceLoopCheckTest#testSeamReformingLiteralPairSurvivesTheFix :: control :: M-SEAM-BLIND',
		'unit.check.RedundantReplaceLoopCheckTest#testSearchEndingWithTheReplacementHeadNotFlagged :: control :: M-SEAM-BLIND',
		'unit.check.RedundantThisCheckTest#testInheritedFromOtherFileBaseFlagged :: control :: M-INHERITS-FALSE',
		'unit.check.RedundantToStringCheckTest#testMethodReturningTypedefOfNullNotFixed :: control :: M-TOSTRING-RETURN-TRUSTED',
		'unit.check.RedundantUpcastTest#testAnOperandNamedLikeAProjectSubtypeIsNotUpcast :: control :: M-SUBTYPE-START-SIMPLE-NAME',
		'unit.check.RedundantUpcastTest#testNamesakeSupertypeIsNotTheCastTarget :: control :: M-SUBTYPE-TARGET-SIMPLE-NAME',
		'unit.check.RedundantUpcastTest#testUpcastFlagged :: control :: M-ISSUBTYPE-FALSE',
		'unit.check.ReflectionMemoTest#testARewrittenScopeFileIsReRead :: control :: M-REFLECTION-MEMO-STALE',
		'unit.check.ReflectionMemoTest#testASecondScopeIsNotAnsweredFromTheFirst :: control :: M-REFLECTION-MEMO-STALE',
		'unit.check.ReflectionMemoTest#testTheSurfaceIsMemoisedWithinARun :: control :: M-REFLECTION-MEMO-DEAD',
		'unit.check.RegionTerminatorFixTest#testCollapsibleIfCarriesTheTerminator :: control :: M-REGION-TERM-OFF',
		'unit.check.RegionTerminatorFixTest#testEmptyStatementKeepsARegionTerminator :: control :: M-REGION-TERM-OFF',
		'unit.check.RegionTerminatorFixTest#testInvertRefusesAnUnterminatedThenRegion :: control :: M-INVERT-REGION-UNGUARDED',
		'unit.check.RegionTerminatorFixTest#testInvertSwapsTheTerminatorWithTheRegion :: control :: M-REGION-TERM-OFF',
		'unit.check.RegionTerminatorFixTest#testPreferSwitchDoesNotDoubleTheTerminator :: guard :: ',
		'unit.check.RegionTerminatorFixTest#testRedundantElseCarriesTheTerminator :: control :: M-REGION-TERM-OFF',
		'unit.check.ReturnReassignTernaryCheckTest#testNegatedGuardEmitsPositiveTernary :: control :: M-RRT-NO-ORIENT,M-NEGCOND-SWAP-OFF',
		'unit.check.ScratchFieldCheckTest#testABuildMacroDeclinesUnlessAnOracleVerifies :: control :: M-SCRATCH-MACRO-IGNORED',
		'unit.check.ScratchFieldCheckTest#testAClosureOccurrenceIsNotReported :: control :: M-SCRATCH-CLOSURE',
		'unit.check.ScratchFieldCheckTest#testAConstructorConstructingIsNoRecursion :: control :: M-SCRATCH-CTOR-RECURSES',
		'unit.check.ScratchFieldCheckTest#testAFieldOfTwoMethodsIsNotReported :: control :: M-SCRATCH-ONE-METHOD',
		'unit.check.ScratchFieldCheckTest#testALoopBodyWriteDoesNotDominateAfterTheLoop :: control :: M-SCRATCH-CONDITIONAL-KEEPS',
		'unit.check.ScratchFieldCheckTest#testAMethodCalledOnTheValueDeclines :: control :: M-SCRATCH-LIFETIME-OFF',
		'unit.check.ScratchFieldCheckTest#testAModifiedFieldIsNotReported :: control :: M-SCRATCH-MODIFIERS',
		'unit.check.ScratchFieldCheckTest#testANameInAStringIsNotReported :: control :: M-SCRATCH-REFLECTION-OFF',
		'unit.check.ScratchFieldCheckTest#testANonTrivialConstructionDeclines :: control :: M-SCRATCH-TRIVIAL-CTOR-ANY',
		'unit.check.ScratchFieldCheckTest#testAOneArmedWriteDoesNotDominate :: control :: M-SCRATCH-BRANCH-OPTIMISTIC',
		'unit.check.ScratchFieldCheckTest#testAReadAfterTheWriteOfItsIterationIsDominated :: control :: M-SCRATCH-SILENT',
		'unit.check.ScratchFieldCheckTest#testAReadBeforeAnyWriteIsNotDominated :: control :: M-SCRATCH-DOMINANCE-OFF',
		'unit.check.ScratchFieldCheckTest#testARecursiveMethodDeclines :: control :: M-SCRATCH-RECURSION-OFF',
		'unit.check.ScratchFieldCheckTest#testAScratchFieldBecomesALocal :: control :: M-SCRATCH-SILENT',
		'unit.check.ScratchFieldCheckTest#testASubtypeMentioningTheFieldIsNotReported :: control :: M-SCRATCH-CONFINED-OFF',
		'unit.check.ScratchFieldCheckTest#testATakenNameKeepsTheFieldName :: control :: M-SCRATCH-NAME-UNCHECKED',
		'unit.check.ScratchFieldCheckTest#testATrivialConstructionInitializerIsDropped :: control :: M-SCRATCH-SILENT',
		'unit.check.ScratchFieldCheckTest#testATryBodyWriteDoesNotDominate :: control :: M-SCRATCH-TRY-ALWAYS',
		'unit.check.ScratchFieldCheckTest#testAValueTypeMayBeCalledOn :: control :: M-SCRATCH-VALUE-TYPES-OFF',
		'unit.check.ScratchFieldCheckTest#testAWriteOnlyFieldIsNotReported :: control :: M-SCRATCH-WRITE-ONLY',
		'unit.check.ScratchFieldCheckTest#testAnImpureInitializerDeclines :: control :: M-SCRATCH-INIT-OFF',
		'unit.check.ScratchFieldCheckTest#testAnRttiTypeIsNotReported :: control :: M-SCRATCH-RTTI-OFF',
		'unit.check.ScratchFieldCheckTest#testAnUntypedFieldDeclines :: control :: M-SCRATCH-UNTYPED',
		'unit.check.ScratchFieldCheckTest#testAnotherReceiversMemberIsNotReported :: control :: M-SCRATCH-FOREIGN-OFF',
		'unit.check.ScratchFieldCheckTest#testSeveralWritesDeclareAVar :: control :: M-SCRATCH-SILENT',
		'unit.check.ScratchFieldCheckTest#testWritesInBothArmsHaveNoDeclarationSlot :: control :: M-SCRATCH-SLOT-ANYWHERE',
		'unit.check.ShadowingCaseBinderCheckTest#testUnprovenSubjectRefused :: control :: M-SHADOWING-BINDER-UNPROVEN',
		'unit.check.ShadowingLocalCheckTest#testFixKeepsAShadowWhoseHiddenBindingIsReadAfter :: control :: '
			+ 'M-SHADOWING-LOCAL-OUTER-READ-IGNORED',
		'unit.check.ShadowingLocalCheckTest#testFixRefusesAnAssignmentThatChangesWhatSomethingReads :: control :: '
			+ 'M-SHADOWING-LOCAL-CAPTURE-IGNORED',
		'unit.check.ShadowingLocalCheckTest#testFixRenamesTheInnerAfterItsWrittenType :: control :: M-SHADOWING-LOCAL-NO-RENAME',
		'unit.check.ShadowingLocalCheckTest#testFixTurnsASameBlockRedeclarationIntoAnAssignment :: control :: '
			+ 'M-SHADOWING-LOCAL-NO-ASSIGNMENT',
		'unit.check.ShadowingParameterCheckTest#testFixLeavesAParameterNoWrittenTypeNames :: control :: M-SHADOWING-PARAM-ANY-TYPE',
		'unit.check.ShadowingParameterCheckTest#testFixRenamesATypedParameterAfterItsWrittenType :: control :: '
			+ 'M-SHADOWING-PARAM-NO-RENAME',
		'unit.check.ShortenTypeRefCheckTest#testASingleSurvivingOccurrenceEarnsNoImport :: control :: M-SHORTEN-IMPORT-THRESHOLD-ONE',
		'unit.check.SimplifyBooleanReturnChainCheckTest#testCommentInAFlatChainIsNotDropped :: control :: M-RETURN-CHAIN-COMMENT-ADMITTED',
		'unit.check.SimplifyBooleanReturnChainCheckTest#testNegatedConjunctionGuardRegroups :: control :: '
			+ 'M-GUARD-CHAIN-NEGATED-RUN-DROPPED',
		'unit.check.SimplifyBooleanReturnChainCheckTest#testStrandedNullTestRegroups :: control :: M-NARROWING-OR-FLAT',
		'unit.check.SimplifyBooleanReturnChainCheckTest#testStrandedNullTestWithCommentNotReduced :: guard :: ',
		'unit.check.SimplifyBooleanTernaryCheckTest#testCompoundNullTestBeforeReuseNotSimplified :: control :: '
			+ 'M-NARROWING-OR-COMPOUND-ADMITTED',
		'unit.check.SimplifyBooleanTernaryCheckTest#testStrandedNullTestInBranchRegroups :: control :: M-TERNARY-OR-BRANCH-UNREAD',
		'unit.check.SimplifyBooleanTernaryCheckTest#testStrandedNullTestRegroupsInNegatedAnd :: control :: M-OR-LEAVES-NEGATED-AND-OPAQUE',
		'unit.check.SimplifyBooleanTernaryCheckTest#testStrandedNullTestRegroupsInOr :: control :: '
			+ 'M-NARROWING-OR-FLAT,M-OR-LEAVES-OR-OPAQUE',
		'unit.check.SimplifyBooleanTernaryCheckTest#testStrandedNullTestWithCommentNotSimplified :: control :: '
			+ 'M-NARROWING-OR-INNER-COMMENT-ADMITTED',
		'unit.check.SimplifyBooleanTernaryCheckTest#testStrandedNullTestWithGlueCommentNotSimplified :: control :: '
			+ 'M-NARROWING-OR-GLUE-COMMENT-ADMITTED',
		'unit.check.StaticConstantCheckTest#testScalarInstanceFinalFlagged :: control :: M-BUILDMACRO-TRUE',
		'unit.check.StaticReflectionReachTest#testAClassReifyingBuildMacroKeepsTheGate :: control :: M-STATICREACH-REIFY-BLIND',
		'unit.check.StaticReflectionReachTest#testAClassSourceInAnOpaqueRegionKeepsTheGate :: control :: '
			+ 'M-STATICREACH-OPAQUE-SOURCE-BLIND',
		'unit.check.StaticReflectionReachTest#testAConsumedGetClassDeletes :: control :: M-STATICREACH-CONSUMER-NONE',
		'unit.check.StaticReflectionReachTest#testADefinitionLookupByAComputedNameKeepsTheGate :: control :: '
			+ 'M-STATICREACH-DEFINITION-BLIND',
		'unit.check.StaticReflectionReachTest#testAJsClassHandleKeepsTheGate :: control :: M-STATICREACH-JS-HANDLE-BLIND',
		'unit.check.StaticReflectionReachTest#testALiteralNamingTheOwnerKeepsTheGate :: control :: M-STATICREACH-TYPEPATH-BLIND',
		'unit.check.StaticReflectionReachTest#testAReceiverlessIsOfTypeNeedsUsingStd :: control :: M-STATICREACH-USING-STD-ASSUMED',
		'unit.check.StaticReflectionReachTest#testAStaticNoClassValueReachesIsDeleted :: control :: M-STATICREACH-NEVER',
		'unit.check.StaticReflectionReachTest#testAStringInAMacroFileKeepsTheGate :: control :: M-STATICREACH-MACRO-BLIND',
		'unit.check.StaticReflectionReachTest#testAStringInANativeCarrierKeepsTheGate :: control :: M-STATICREACH-CARRIER-BLIND',
		'unit.check.StaticReflectionReachTest#testAStringNamingAClassSourceKeepsTheGate :: control :: M-STATICREACH-SOURCE-STRING-BLIND',
		'unit.check.StaticReflectionReachTest#testASubclassAsAValueKeepsTheGate :: control :: M-STATICREACH-SUBTYPE-BLIND',
		'unit.check.StaticReflectionReachTest#testAWhitelistedConsumerOfTheClassNameDeletes :: control :: M-STATICREACH-CONSUMER-NONE',
		'unit.check.StaticReflectionReachTest#testAnAliasAsAValueKeepsTheGate :: control :: M-STATICREACH-ALIAS-BLIND',
		'unit.check.StaticReflectionReachTest#testAnExtensionOnTheClassKeepsTheGate :: control :: M-STATICREACH-RECEIVER-BLIND',
		'unit.check.StaticReflectionReachTest#testAnInstanceFieldKeepsTheStringGate :: control :: M-STATICREACH-INSTANCE',
		'unit.check.StaticReflectionReachTest#testAnUnconsumedGetClassKeepsTheGate :: control :: M-STATICREACH-SOURCE-BLIND',
		'unit.check.StaticReflectionReachTest#testGetClassOfThisInAMacroModuleKeepsTheGate :: control :: M-STATICREACH-MACRO-THIS',
		'unit.check.StaticReflectionReachTest#testGetClassOfThisInAnUnrelatedClassDeletes :: control :: M-STATICREACH-THIS-UNBOUNDED',
		'unit.check.StaticReflectionReachTest#testGetClassOfThisOnTheOwnersChainKeepsTheGate :: control :: M-STATICREACH-THIS-BLIND',
		'unit.check.StaticReflectionReachTest#testTheClassNameAsAValueKeepsTheGate :: control :: M-STATICREACH-VALUE-BLIND',
		'unit.check.StaticReflectionReachTest#testTheCliDeletesADistinctiveStaticOnlyATableSpells :: control :: M-STATICREACH-NEVER',
		'unit.check.StaticReflectionReachTest#testTheOwnerInAnOpaqueRegionKeepsTheGate :: control :: M-STATICREACH-OPAQUE-CHAIN-BLIND',
		'unit.check.StringLiteralDupCheckTest#testMapOfOnlyStringLiteralsIsATable :: control :: M-STRING-LITERAL-DUP-MAP-ENTRY-BLIND',
		'unit.check.StringLiteralDupCheckTest#testMapWithNegativeValuesIsATable :: control :: M-LITERAL-TABLE-NEG-ENTRY-BLIND',
		'unit.check.StringLiteralDupCheckTest#testMapWithNonStringValuesIsATable :: control :: M-STRING-LITERAL-DUP-STRING-ONLY-ENTRIES',
		'unit.check.StringLiteralDupCheckTest#testMixedArrayIsNotATable :: control :: M-STRING-LITERAL-DUP-TABLE-ANY',
		'unit.check.StringLiteralDupCheckTest#testReportOnlyIsDeclaredAndPointsAtExtractConstant :: control :: '
			+ 'M-STRING-LITERAL-DUP-REASON-MUTE',
		'unit.check.StringLiteralDupCheckTest#testSmallCollectionOfOnlyLiteralsIsATable :: control :: M-STRING-LITERAL-DUP-TABLE-ARITY',
		'unit.check.StructuralConformanceProofTest#testANamesakeOfAnotherPackageRefutes :: control :: M-STRUCT-MUTABLE-SAME-DECL',
		'unit.check.StructuralConformanceProofTest#testAReadOnlyStructureFieldTakesASubtype :: control :: M-STRUCT-READONLY-INVARIANT',
		'unit.check.StructuralConformanceProofTest#testAReadOnlyStructureFieldTakesAnAbstractThroughItsClause :: control :: M-UNIFY-ABSTRACT-OFF',
		'unit.check.StructuralConformanceProofTest#testAliasedStructureMemberTypeStillPins :: control :: M-STRUCT-ALIAS-OPAQUE',
		'unit.check.StructuralConformanceProofTest#testAnonStructureNominalStillPins :: control :: M-STRUCT-ANON-CLOSED',
		'unit.check.StructuralConformanceProofTest#testDifferentDeclaredTypeDoesNotPin :: control :: M-STRUCT-NOMINAL-OPEN',
		'unit.check.StructuralConformanceProofTest#testDynamicStructureMemberStillPins :: control :: M-STRUCT-DYNAMIC-CLOSED',
		'unit.check.StructuralConformanceProofTest#testExplicitVarFormStructureRefutesToo :: control :: M-STRUCT-ANON-VAR-KEY',
		'unit.check.StructuralConformanceProofTest#testNullWrappedStructureMemberTypeStillPins :: control :: M-STRUCT-NULL-OPAQUE',
		'unit.check.StructuralConformanceProofTest#testTypeParameterStructureMemberStillPins :: control :: M-STRUCT-TYPEPARAM-CLOSED',
		'unit.check.StructuralConformanceProofTest#testUnresolvableStructureMemberTypeRefutes :: control :: M-STRUCT-UNRESOLVED-OPEN',
		'unit.check.StructuralConformanceProofTest#testUnresolvableSupertypeSuppliesNoMember :: control :: M-STRUCT-DECLARES-LOOSE',
		'unit.check.SwallowedExceptionCheckTest#testAssignedFieldOrParameterStillFlagged :: control :: M-SWALLOW-OUTCOME-DECL-KIND',
		'unit.check.SwallowedExceptionCheckTest#testCallInTheBodyStillFlagged :: control :: M-SWALLOW-OUTCOME-EVERY-STMT',
		'unit.check.SwallowedExceptionCheckTest#testComputedValueStillFlagged :: control :: '
			+ 'M-SWALLOW-OUTCOME-COMPOUND,M-SWALLOW-OUTCOME-VALUE',
		'unit.check.SwallowedExceptionCheckTest#testFlagNotReadAfterTheTryStillFlagged :: control :: '
			+ 'M-SWALLOW-OUTCOME-READ-KIND,M-SWALLOW-OUTCOME-READ-AFTER',
		'unit.check.SwallowedExceptionCheckTest#testReadInASiblingBranchStillFlagged :: control :: M-SWALLOW-OUTCOME-STMT-LIST',
		'unit.check.SwallowedExceptionCheckTest#testReadOfAnotherBindingStillFlagged :: control :: M-SWALLOW-OUTCOME-READ-BINDING',
		'unit.check.SwallowedExceptionCheckTest#testReadOnlyAfterTheEnclosingClosureStillFlagged :: control :: M-SWALLOW-OUTCOME-FN-BOUND',
		'unit.check.TailMergeCheckTest#testStructuralIdentityHalfNeeded :: control :: M-TAILMERGE-NORM-ONLY',
		'unit.check.TailMergeCheckTest#testSwitchCaseOutOfScope :: control :: M-TAILMERGE-FALL-KEPT',
		'unit.check.ThreadSafetyAllocationTest#testAComputedReflectiveWriteMakesTheFieldUnknown :: control :: '
			+ 'M-TS-REFLECT-COMPUTED,M-TS-REFLECT-MAYWRITE,M-TS-REFLECT-HANDED-CALLEE',
		'unit.check.ThreadSafetyAllocationTest#testAConstructionRunsOnItsOwnClass :: control :: M-TS-ALLOC-NEW',
		'unit.check.ThreadSafetyAllocationTest#testALibraryClassRunsNoProjectOverride :: control :: M-TS-ALLOC-LIBRARY',
		'unit.check.ThreadSafetyAllocationTest#testARunOverPartOfTheProjectSealsNoField :: control :: M-TS-ALLOC-COMPLETE',
		'unit.check.ThreadSafetyAllocationTest#testASealedFieldRunsOnlyItsClassesOverrides :: control :: M-TS-ALLOC-OFF',
		'unit.check.ThreadSafetyAllocationTest#testAnAliasNamedAsAProjectClassNamesWhatItAliases :: control :: M-TS-ALLOC-ALIAS',
		'unit.check.ThreadSafetyAllocationTest#testAnUndeclaredNameNoImportNamesRunsEveryOverride :: control :: M-TS-ALLOC-LIBRARY-PATH',
		'unit.check.ThreadSafetyAllocationTest#testAnyOtherWriteMakesTheFieldUnknown :: control :: M-TS-ALLOC-ANY-WRITE',
		'unit.check.ThreadSafetyAllocationTest#testEveryReflectiveEscapeMakesTheFieldUnknown :: control :: '
			+ 'M-TS-REFLECT-DYNACC,M-TS-REFLECT-HANDED,M-TS-REFLECT-INDEX-ANY,M-TS-REFLECT-INDEX-ELEMENT',
		'unit.check.ThreadSafetyAllocationTest#testTheDeclaredValueCounts :: control :: M-TS-ALLOC-DECLARED',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testABoundOverTheBudgetStillRepeats :: control :: M-TS-BOUND-BUDGET',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testABoundedLoopRunsAsOnce :: control :: M-TS-BOUND-OFF',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testABoundedLoopUnderALockIsBrief :: control :: M-TS-BOUND-UNDER',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testALabelNamingSeveralLoopsBindsNone :: control :: M-TS-BOUND-LABEL-SEVERAL',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testALoopThatBlocksNothingTakesNoRank :: control :: M-TS-LABEL-RANK-SINK',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testAMalformedCallDropsTheEntry :: control :: M-TS-BOUND-CALL-SHAPE',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testASitePatternDropsTheEntry :: control :: M-TS-BOUND-SITE-PATTERN',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testAZeroCostDropsTheEntry :: control :: M-TS-BOUND-COST-ZERO',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testAnEntryForAnotherCallLeavesTheLoopRepeating :: control :: M-TS-BOUND-CALL',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testAnEntryOverNestedLoopsBindsNone :: control :: M-TS-BOUND-ONE',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testBoundsMultiplyAlongTheWay :: control :: '
			+ 'M-TS-BOUND-ACROSS,M-TS-BOUND-ACROSS-HOLD,M-TS-BOUND-NOTE',
		'unit.check.ThreadSafetyBoundedRepeatsTest#testNestedBoundsMultiply :: control :: M-TS-BOUND-PRODUCT',
		'unit.check.ThreadSafetyCarriedHoldTest#testACalleeGivingTheLockBackCarriesNothing :: guard :: ',
		'unit.check.ThreadSafetyCarriedHoldTest#testAComputedReflectiveWriteNamesNoObject :: control :: '
			+ 'M-TS-REFLECT-COMPUTED,M-TS-REFLECT-EXTENSION,M-TS-REFLECT-INDEX,M-TS-REFLECT-REACH,M-TS-REFLECT-SUBTYPES,'
			+ 'M-TS-REFLECT-SUPERTYPES,M-TS-REFLECT-MAYWRITE,M-TS-REFLECT-FINAL,M-TS-REFLECT-ANY',
		'unit.check.ThreadSafetyCarriedHoldTest#testAConstructorWritingAnotherObjectsFieldNamesNoObject :: control :: M-TS-PATH-OWN',
		'unit.check.ThreadSafetyCarriedHoldTest#testADominatedTakeInACalleeOnTheHeldObjectIsBrief :: control :: M-TS-CARRY-OFF',
		'unit.check.ThreadSafetyCarriedHoldTest#testAFieldWrittenOutsideTheConstructorNamesNoObject :: control :: M-TS-PATH-STABLE-ANY',
		'unit.check.ThreadSafetyCarriedHoldTest#testAFileTheRunCannotParseLeavesTheProjectUncovered :: control :: M-TS-COVER-PARSED',
		'unit.check.ThreadSafetyCarriedHoldTest#testANestedRestatementClosesNoProjectOfItsOwn :: control :: M-TS-COVER-OUTERMOST',
		'unit.check.ThreadSafetyCarriedHoldTest#testAPathOfStableFieldsNamesTheHeldObject :: control :: M-TS-PATH-TWO-LINK,M-TS-PATH-CTOR',
		'unit.check.ThreadSafetyCarriedHoldTest#testARetakeInACalleeIsBrief :: control :: M-TS-CARRY-RETAKE',
		'unit.check.ThreadSafetyCarriedHoldTest#testARunOverPartOfTheProjectSeesNotEveryWrite :: control :: '
			+ 'M-TS-PATH-COMPLETE,M-TS-COVER-WALK,M-TS-COVER-NOTE',
		'unit.check.ThreadSafetyCarriedHoldTest#testAStaticVarWrittenInTheConstructorNamesNoObject :: control :: M-TS-PATH-STATIC',
		'unit.check.ThreadSafetyCarriedHoldTest#testATakeOnAnotherObjectIsNotUnderTheHold :: control :: M-TS-CARRY-OBJECT',
		'unit.check.ThreadSafetyCarriedHoldTest#testAWriteInAFunctionTheConstructorMakesIsNoConstructorWrite :: control :: '
			+ 'M-TS-PATH-CTOR-LAMBDA',
		'unit.check.ThreadSafetyCarriedHoldTest#testAnExcludedFileIsNoPartOfTheProject :: control :: M-TS-COVER-EXCLUDE',
		'unit.check.ThreadSafetyCarriedHoldTest#testAnImplementersOrAReflectiveWriteNamesNoObject :: control :: '
			+ 'M-TS-PATH-INTERFACE,M-TS-PATH-REFLECT',
		'unit.check.ThreadSafetyCheckTest#testABriefHoldThroughWrappersKeepsTheLockShort :: control :: '
			+ 'M-TS-WRAPPER-LEAKS,M-TS-WRAPPER-CROSSING',
		'unit.check.ThreadSafetyCheckTest#testACallCycleNothingEntersIsWalked :: control :: M-TS-ORDER-CYCLES-UNWALKED',
		'unit.check.ThreadSafetyCheckTest#testACallbackRegisteredUnderAHoldTakesNothingInOrder :: control :: M-TS-ORDER-FOLLOWS-REFS',
		'unit.check.ThreadSafetyCheckTest#testACalleeCatchingTheThrowerRaisesNothing :: control :: M-TS-THROW-TRY-UNCAUGHT',
		'unit.check.ThreadSafetyCheckTest#testACatchReleasingAndRethrowingIsQuiet :: control :: M-TS-THROW-CATCH-IGNORED',
		'unit.check.ThreadSafetyCheckTest#testAConditionalReleaseIsNoWrapper :: control :: M-TS-WRAPPER-MAY-RELEASE',
		'unit.check.ThreadSafetyCheckTest#testAConditionalTakeIsNoWrapper :: control :: M-TS-WRAPPER-MAY-TAKE',
		'unit.check.ThreadSafetyCheckTest#testAConstructorPublishingItselfFirstHoldsAContendedLock :: control :: M-TS-CTOR-ESCAPE-BLIND',
		'unit.check.ThreadSafetyCheckTest#testAFileWithoutSinksStillShapesTheGraph :: control :: M-TS-GRAPH-CUT',
		'unit.check.ThreadSafetyCheckTest#testAHelperGivingBackTwoLocksEndsTheirHolds :: control :: M-TS-ORDER-HELPER-NEVER-RELEASES',
		'unit.check.ThreadSafetyCheckTest#testAHelperTakingTwoLocksHoldsThemInItsCaller :: control :: M-TS-ORDER-NO-HELPER-HOLDS',
		'unit.check.ThreadSafetyCheckTest#testAHoldAcrossACallReachingAThrowerEscapes :: control :: M-TS-THROW-NO-PROPAGATION',
		'unit.check.ThreadSafetyCheckTest#testAHoldAcrossAnUnresolvedCallMakesTheLockLong :: control :: M-TS-BLIND-CALL-SHORT',
		'unit.check.ThreadSafetyCheckTest#testAHoldInTheOwnersConstructorBlocksNoOne :: control :: M-TS-CTOR-CONTENDED',
		'unit.check.ThreadSafetyCheckTest#testAHoldIsAnchoredAtItsFirstBlockingCall :: control :: M-TS-HOLD-ANCHOR-LAST',
		'unit.check.ThreadSafetyCheckTest#testAHoldIsOneFindingListingItsBlockingCalls :: control :: M-TS-EVIDENCE-UNCAPPED',
		'unit.check.ThreadSafetyCheckTest#testAHoldOfAnUnknownLockNamesThePair :: control :: '
			+ 'M-TS-UNKNOWN-LOCK-UNNAMED,M-TS-B-UNKNOWN-AS-MAIN-ONLY',
		'unit.check.ThreadSafetyCheckTest#testAHoldOfAnotherObjectsLockIsNotReentrantForTheOwnLock :: control :: '
			+ 'M-TS-REENTRANT-HOLDER-ELSEWHERE',
		'unit.check.ThreadSafetyCheckTest#testAHoldOnlyABackgroundThreadTakesIsQuiet :: control :: M-TS-HELD-ANY-THREAD',
		'unit.check.ThreadSafetyCheckTest#testAHoldOnlyAQuietRootRunsIsNotReported :: control :: M-TS-QUIET-HOLD',
		'unit.check.ThreadSafetyCheckTest#testAHoldTakenThroughAWrapperIsTheCallersHold :: control :: M-TS-WRAPPER-NONE',
		'unit.check.ThreadSafetyCheckTest#testALockCallThroughAnUntypedReceiverUnsealsTheMember :: control :: '
			+ 'M-TS-UNNAMED-RECEIVER-SEALED',
		'unit.check.ThreadSafetyCheckTest#testALockHandedAnotherValueStaysUnknown :: control :: M-TS-ALIAS-FOREIGN-VALUE',
		'unit.check.ThreadSafetyCheckTest#testALockHandedToAConstructorKeepsItsName :: control :: M-TS-ALIAS-UNNAMED',
		'unit.check.ThreadSafetyCheckTest#testALockHeldAcrossASleepStallsItsMainThreadTaker :: control :: M-TS-LONG-NEVER-GROWS',
		'unit.check.ThreadSafetyCheckTest#testALockMemberThatEscapesStaysReported :: control :: M-TS-UNSEALED-TRUSTED',
		'unit.check.ThreadSafetyCheckTest#testALockOrderInversionAcrossThreadsIsReported :: control :: M-TS-ORDER-ANCHOR-AT-TAKE',
		'unit.check.ThreadSafetyCheckTest#testALockTakenInALoopIsHeldOnTheNextPass :: control :: M-TS-LOOP-ONE-PASS',
		'unit.check.ThreadSafetyCheckTest#testAMainThreadCallSiteIsOneFinding :: control :: M-TS-SITE-PER-TARGET',
		'unit.check.ThreadSafetyCheckTest#testAMalformedOptionOfANonReportingChainIsSaid :: control :: M-TS-BUILTIN-NEEDS-SINKS',
		'unit.check.ThreadSafetyCheckTest#testAPathThroughAQuietRootIsNotReported :: control :: M-TS-QUIET-IGNORED',
		'unit.check.ThreadSafetyCheckTest#testAQuietRootALoudCallerCallsIsLoud :: control :: M-TS-QUIET-LOUD-CALLER',
		'unit.check.ThreadSafetyCheckTest#testARaisingCallAheadOfTheTakeInItsStepIsQuiet :: control :: M-TS-THROW-BEFORE-TAKE',
		'unit.check.ThreadSafetyCheckTest#testARaisingCallInAStepThatReleasesIsQuiet :: control :: M-TS-THROW-STEP-RELEASES',
		'unit.check.ThreadSafetyCheckTest#testAReassignedParameterAliasesNothing :: control :: M-TS-ALIAS-PARAM-REUSED',
		'unit.check.ThreadSafetyCheckTest#testAReflectedTypeAliasesNothing :: control :: M-TS-ALIAS-REFLECTED',
		'unit.check.ThreadSafetyCheckTest#testAReflectiveConstructionAliasesNothing :: control :: M-TS-ALIAS-REFLECTED-ANY-ARGS',
		'unit.check.ThreadSafetyCheckTest#testAReflectiveConstructionOfAnUnrelatedClassKeepsTheAlias :: control :: '
			+ 'M-TS-ALIAS-REFLECTED-UNTYPED',
		'unit.check.ThreadSafetyCheckTest#testAReflectiveConstructionOfTheFamilyAliasesNothing :: control :: M-TS-ALIAS-REFLECTED-FAMILY',
		'unit.check.ThreadSafetyCheckTest#testAReflectiveConstructionTooShortToReachTheParameterKeepsTheAlias :: control :: '
			+ 'M-TS-ALIAS-REFLECTED-SHORT-REFUSED',
		'unit.check.ThreadSafetyCheckTest#testAReflectiveWriteUnsealsTheMember :: control :: M-TS-SEAL-REFLECT,'
			+ 'M-TS-SEAL-REFLECT-REACH,M-TS-SEAL-REFLECT-LITERAL-ANY,M-TS-SEAL-REFLECT-UNPLACED,M-TS-SEAL-UNPLACED-NOTICE',
		'unit.check.ThreadSafetyCheckTest#testAReleaseOnAnEarlyReturnKeepsTheRestOfTheWindow :: control :: M-TS-WINDOW-IF-RELEASES',
		'unit.check.ThreadSafetyCheckTest#testAReleaseWithoutATakeMakesTheLockLong :: control :: M-TS-CROSSING-IGNORED',
		'unit.check.ThreadSafetyCheckTest#testARetakeOfAHeldReentrantLockIsNoBlockingCall :: control :: M-TS-REENTRANT-IGNORED',
		'unit.check.ThreadSafetyCheckTest#testARetakeOfAnUnlistedLockKindStillBlocks :: control :: M-TS-REENTRANT-ASSUMED',
		'unit.check.ThreadSafetyCheckTest#testARetakeOfTheOwnObjectsLockIsFree :: control :: M-TS-SELF-NEVER',
		'unit.check.ThreadSafetyCheckTest#testARethrowOfWhatTheBodyThrewHoldingEscapesHeld :: control :: M-TS-THROW-CATCH-ENTRY-UNHELD',
		'unit.check.ThreadSafetyCheckTest#testARewrittenStaticSourceIsNoRetake :: control :: M-TS-ALIAS-STATIC-REWRITTEN',
		'unit.check.ThreadSafetyCheckTest#testAShortLockTakenOnMainIsQuiet :: control :: M-TS-LOCK-ALWAYS-BLOCKS',
		'unit.check.ThreadSafetyCheckTest#testASinkOfOneChainIsAPlainCallInAnother :: control :: M-TS-TAINT-UNION-SINK',
		'unit.check.ThreadSafetyCheckTest#testATakeInTheOwnersConstructorOrdersNothing :: control :: M-TS-ORDER-CTOR-CONTENDED',
		'unit.check.ThreadSafetyCheckTest#testATakeOfAnotherObjectsLockBlocksUnderAReentrantHold :: control :: M-TS-REENTRANT-ANY-OBJECT',
		'unit.check.ThreadSafetyCheckTest#testAThrowBetweenTakeAndReleaseLeavesTheLockHeld :: control :: M-TS-THROW-UNRAISED',
		'unit.check.ThreadSafetyCheckTest#testAThrowInALambdaMadeUnderTheHoldIsQuiet :: control :: M-TS-THROW-NESTED-FN',
		'unit.check.ThreadSafetyCheckTest#testAThrowUnderAHelpersLocksLeavesBothHeld :: control :: M-TS-THROW-HELPER-HOLDS-UNREAD',
		'unit.check.ThreadSafetyCheckTest#testAWrapperCalledThroughAnUntypedReceiverKeepsItsTakeLong :: control :: M-TS-WRAPPER-UNRESOLVED',
		'unit.check.ThreadSafetyCheckTest#testAWrapperOnAnotherObjectBlocksUnderAReentrantHold :: control :: '
			+ 'M-TS-REENTRANT-WRAPPER-ELSEWHERE',
		'unit.check.ThreadSafetyCheckTest#testAWrapperReachedThroughAnInterfaceTakesTheLock :: control :: M-TS-WRAPPER-NO-PASS-THROUGH',
		'unit.check.ThreadSafetyCheckTest#testAnAliasIsNeverARetakeOfTheHoldersOwnLock :: control :: M-TS-ALIAS-SELF-REENTRANT',
		'unit.check.ThreadSafetyCheckTest#testAnEscapingSourceAliasesNothing :: control :: M-TS-ALIAS-SOURCE-UNSEALED',
		'unit.check.ThreadSafetyCheckTest#testAnInversionBetweenBackgroundStepsIsQuiet :: control :: M-TS-ORDER-BG-AS-MAIN',
		'unit.check.ThreadSafetyCheckTest#testAnUnknownLockOrdersNothing :: control :: M-TS-ORDER-UNKNOWN-LOCK',
		'unit.check.ThreadSafetyCheckTest#testAnotherPathToAQuietSinkStillReports :: control :: M-TS-QUIET-SWALLOWS',
		'unit.check.ThreadSafetyCheckTest#testEachCallSiteJudgedByItsOwnChain :: control :: M-TS-FIRST-FILE-LISTS',
		'unit.check.ThreadSafetyCheckTest#testLockHeldAcrossABlockingGetterFlagged :: control :: M-TS-ACCESSOR-TAINT',
		'unit.check.ThreadSafetyCheckTest#testNoFindingInAFileWhoseChainWritesNoOption :: control :: M-TS-REPORT-UNGATED',
		'unit.check.ThreadSafetyCheckTest#testOneLockOrderOnEveryThreadIsQuiet :: control :: M-TS-ORDER-RETAKE-STEPS',
		'unit.check.ThreadSafetyCheckTest#testShadowedTypeParameterKeepsTheFieldsBound :: control :: M-GRAPH-BOUND-DECL-SCOPE',
		'unit.check.ThreadSafetyCheckTest#testTwoTakesHeldAtOneThrowAreOneFinding :: control :: M-TS-THROW-PER-TAKE',
		'unit.check.ThreadSafetyCheckTest#testWhatAQuietRootRegistersRunsLoud :: control :: M-TS-QUIET-INTO-CALLBACK',
		'unit.check.ThreadSafetyConditionsTest#testABareNeverInvokesNameMatchesAnUnresolvedCall :: control :: M-TS-NEVER-INVOKES-BY-NAME',
		'unit.check.ThreadSafetyConditionsTest#testABoolLiteralArgumentDecidesTheCalleesBranch :: control :: '
			+ 'M-TS-ARG-UNBOUND,M-TS-STATES-UNCONDITIONED',
		'unit.check.ThreadSafetyConditionsTest#testACallAnOverloadTakesBindsNoneOfTheBodysParameters :: control :: '
			+ 'M-TS-OVERLOAD-OWN-SELECTED,M-TS-OVERLOAD-VERDICTS',
		'unit.check.ThreadSafetyConditionsTest#testAConstructionArgumentDecidesTheConstructorsBranch :: control :: M-TS-NEW-UNBOUND',
		'unit.check.ThreadSafetyConditionsTest#testAFieldInitializersConstructionBindsItsArguments :: control :: M-TS-INIT-SITE-UNREAD',
		'unit.check.ThreadSafetyConditionsTest#testAFieldsTypeResolvesWhereItsDeclarationWritesIt :: control :: '
			+ 'M-ARGTYPE-FIELD-FILE,M-ARGTYPE-STATIC-FILE',
		'unit.check.ThreadSafetyConditionsTest#testAFinalLocalDecidesOnlyTheReadsItBinds :: control :: M-TS-COND-LOCAL-ANY-BLOCK',
		'unit.check.ThreadSafetyConditionsTest#testAFunctionValueWrittenUnderAGuardIsHandedOnOnlyWhereItHolds :: control :: M-TS-LAMBDA-SITE-UNGUARDED',
		'unit.check.ThreadSafetyConditionsTest#testAHandlerHandedToANeverInvokesTargetRunsNowhereFromThere :: control :: '
			+ 'M-TS-NEVER-INVOKES-BY-TARGET',
		'unit.check.ThreadSafetyConditionsTest#testAHoldABoolArgumentRulesOutHoldsNothingInOrder :: control :: '
			+ 'M-TS-ORDER-HOLD-UNCONDITIONED',
		'unit.check.ThreadSafetyConditionsTest#testAHoldAcrossACallBlockingOnlyOnAnotherThreadIsQuiet :: control :: '
			+ 'M-TS-TAINT-UNCONDITIONED',
		'unit.check.ThreadSafetyConditionsTest#testAMainThreadCheckPropertyIsReadThroughItsGetter :: control :: M-TS-MAIN-CHECK-NO-GETTER',
		'unit.check.ThreadSafetyConditionsTest#testANullArgumentToAParameterWithADefaultLeavesTheDefault :: control :: M-TS-NULL-DEFAULT-UNREAD',
		'unit.check.ThreadSafetyConditionsTest#testANullTestOfALocalTheCheckChoseIsTheChecksAnswer :: control :: M-TS-NULL-LOCAL-UNREAD',
		'unit.check.ThreadSafetyConditionsTest#testAParameterHandedOnCarriesItsValue :: control :: '
			+ 'M-TS-ARG-PARAM-UNREAD,M-TS-STATES-UNBOUND',
		'unit.check.ThreadSafetyConditionsTest#testAPlainClassArgumentSkipsAnOptionalParameterOfAnUnrelatedClass :: control :: M-ARGFIT-PLAIN-OFF,M-UNIFY-CHAIN-OPEN',
		'unit.check.ThreadSafetyConditionsTest#testAStoredValueAnUnresolvedCallMayRunKeepsTheAssignersContext :: control :: '
			+ 'M-TS-STORE-SEALED-BLIND',
		'unit.check.ThreadSafetyConditionsTest#testAStoredValueInvokedOnTheMainThreadIsReachedThroughTheInvoker :: control :: '
			+ 'M-TS-STORE-UNMIRRORED',
		'unit.check.ThreadSafetyConditionsTest#testAStringAffixGuardAnotherUsingMayBindDecidesNothing :: control :: M-TS-AFFIX-USINGS-UNCHECKED',
		'unit.check.ThreadSafetyConditionsTest#testAStringTheCalleesAffixGuardTestsDecidesIt :: control :: M-TS-AFFIX-UNREAD,M-TS-STRING-ATOM-OFF',
		'unit.check.ThreadSafetyConditionsTest#testATakeABoolArgumentRulesOutOrdersNothing :: control :: M-TS-ORDER-UNCONDITIONED',
		'unit.check.ThreadSafetyConditionsTest#testAValueStoredInADynamicMemberRunsWhereTheMemberRuns :: control :: M-TS-STORE-INERT',
		'unit.check.ThreadSafetyConditionsTest#testAWrittenParameterIsNotTracked :: control :: M-TS-PARAM-WRITE-IGNORED',
		'unit.check.ThreadSafetyConditionsTest#testAnAbstractArgumentBindsTheParameterItCastsTo :: control :: '
			+ 'M-ARGFIT-CAST-OFF,M-UNIFY-ABSTRACT-OFF,M-ARGTYPE-HELD-GRAPH',
		'unit.check.ThreadSafetyConditionsTest#testAnArgumentAnAbstractMayTakeLeavesBothBindings :: control :: M-ARGFIT-UNKNOWN-MISFITS',
		'unit.check.ThreadSafetyConditionsTest#testAnArgumentHaxeMaySkipAnOptionalParameterForBindsNothing :: control :: '
			+ 'M-TS-SKIP-UNCHECKED',
		'unit.check.ThreadSafetyConditionsTest#testAnArgumentOfALibraryTypeResolvesInTheResolutionScope :: control :: '
			+ 'M-ARGTYPE-RESOLUTION-OFF',
		'unit.check.ThreadSafetyConditionsTest#testAnArgumentTypedByArithmeticBindsItsOwnParameter :: control :: M-WALK-ARITHMETIC-OFF,M-ARGTYPE-STATIC-OFF',
		'unit.check.ThreadSafetyConditionsTest#testAnEnumAbstractValueIsOfItsAbstract :: control :: M-ENUM-VALUE-OFF',
		'unit.check.ThreadSafetyConditionsTest#testAnEnumAbstractValueIsOfItsAbstractInEveryDeclaredBuild :: control :: M-BUILDS-FILTER-OFF',
		'unit.check.ThreadSafetyConditionsTest#testAnInheritedConstructorTakesTheArgumentsOfItsSupertypes :: control :: M-TS-NEW-UNBOUND',
		'unit.check.ThreadSafetyConditionsTest#testAnOmittedArgumentTakesItsBoolDefault :: control :: M-TS-DEFAULT-UNREAD',
		'unit.check.ThreadSafetyConditionsTest#testAnOmittedOptionalParameterIsNull :: control :: M-TS-NULL-PARAM-UNREAD',
		'unit.check.ThreadSafetyConditionsTest#testArithmeticOverAnAbstractIsTypedByItsOperatorOverload :: control :: '
			+ 'M-ARGTYPE-OVERLOAD-OFF,M-OPS-FIRST-TAKEN',
		'unit.check.ThreadSafetyConditionsTest#testCodeAfterAnEarlyExitOnTheCheckRunsOnTheOtherThreads :: control :: '
			+ 'M-TS-EARLY-EXIT-UNREAD',
		'unit.check.ThreadSafetyConditionsTest#testEveryWayACallMayBindDecidesTogether :: control :: M-TS-ARG-SETS-UNKNOWN',
		'unit.check.ThreadSafetyConditionsTest#testOneCallBindsAnewUnderEachValuationOfItsCaller :: control :: M-TS-BIND-MEMO-ONE-VALUATION',
		'unit.check.ThreadSafetyConditionsTest#testTheOffMainBranchOfAMainThreadCheckIsNoMainStall :: control :: M-TS-MAIN-CHECK-IGNORED,M-TS-SITE-MEMO-BY-CALLER',
		'unit.check.ThreadSafetyConditionsTest#testUnderAClosedWorldAConstructorStaysARoot :: control :: M-TS-SEAL-CTOR',
		'unit.check.ThreadSafetyConditionsTest#testUnderAClosedWorldAHoldNoThreadRunsIsQuiet :: control :: M-TS-DEAD-HOLDS-KEPT',
		'unit.check.ThreadSafetyConditionsTest#testUnderAClosedWorldAMethodAnUnresolvedCallMayNameStaysARoot :: control :: '
			+ 'M-TS-SEAL-UNRESOLVED',
		'unit.check.ThreadSafetyConditionsTest#testUnderAClosedWorldAnOverrideStaysARoot :: control :: M-TS-SEAL-OVERRIDE',
		'unit.check.ThreadSafetyConditionsTest#testUnderAClosedWorldAnUncalledMethodRunsNowhere :: control :: M-TS-CLOSED-WORLD-UNREAD',
		'unit.check.ThreadSafetyConditionsTest#testUnderAClosedWorldAnUnindexedInterfacesMemberStaysARoot :: control :: '
			+ 'M-TS-SEAL-SUPERTYPE',
		'unit.check.ThreadSafetyCostTest#testAFunctionAroundTheSiteStartsTheCountAfresh :: control :: '
			+ 'M-TS-REPEAT-NO-BOUNDARY,M-TS-UPWARD-INERT',
		'unit.check.ThreadSafetyCostTest#testAHoldOverAShortSinkOnceIsInfo :: control :: M-TS-LONG-BY-ANY-SPAN',
		'unit.check.ThreadSafetyCostTest#testALoopAroundTheWholeHoldIsShort :: control :: M-TS-REPEAT-UNDER-OUTER',
		'unit.check.ThreadSafetyCostTest#testARepeatingSiteOwnsOneWarning :: control :: '
			+ 'M-TS-SITE-PER-SINK,M-TS-SITE-GROW,M-TS-SITE-SUBJECT',
		'unit.check.ThreadSafetyCostTest#testAShortSinkBelowARepeatingCallerWarns :: control :: M-TS-REPEAT-UPWARD-NONE,M-TS-OWNER-OFF',
		'unit.check.ThreadSafetyCostTest#testAShortSinkCalledOnceIsInfo :: control :: M-TS-SHORT-SINKS-IGNORED',
		'unit.check.ThreadSafetyCostTest#testAShortSinkInALoopWarns :: control :: M-TS-REPEAT-NO-LOOPS',
		'unit.check.ThreadSafetyCostTest#testAWarningNamesOnlyTheLongCalls :: control :: M-TS-EVIDENCE-PLAIN',
		'unit.check.ThreadSafetyCostTest#testAnIteratesCallbackRepeats :: control :: M-TS-REPEAT-NO-ITERATES',
		'unit.check.ThreadSafetyCostTest#testRecursionRepeatsAShortSink :: control :: M-TS-REPEAT-NO-RECURSION,M-TS-OWNER-SELF-MOVED',
		'unit.check.ThreadSafetyCostTest#testTheIterableOfAForRunsOnce :: control :: M-TS-REPEAT-ITERABLE',
		'unit.check.ThreadSafetyCostTest#testTheNearestRepeatingCallerOwnsTheWarning :: control :: M-TS-OWNER-FARTHEST',
		'unit.check.ThreadSafetyDeadCatchTest#testABindingElsewhereInTheFunctionDoesNotBindTheRead :: control :: '
			+ 'M-TS-DEADCATCH-BINDING-SCOPE',
		'unit.check.ThreadSafetyDeadCatchTest#testACallOffAValueMayThrow :: control :: M-TS-DEADCATCH-RECEIVER',
		'unit.check.ThreadSafetyDeadCatchTest#testACatchAroundANonThrowingCallIsNoPath :: control :: M-TS-DEADCATCH-OFF',
		'unit.check.ThreadSafetyDeadCatchTest#testAFieldReadOffAValueMakesTheCatchAPath :: control :: M-TS-DEADCATCH-FIELD',
		'unit.check.ThreadSafetyDeadCatchTest#testAPropertyReadRunsItsGetter :: control :: M-TS-DEADCATCH-PROPERTY,M-TS-DEADCATCH-BINDING',
		'unit.check.ThreadSafetyDeadCatchTest#testAnInterpolatedStringRunsWhatItInterpolates :: control :: M-TS-DEADCATCH-INTERP',
		'unit.check.ThreadSafetyDeadCatchTest#testAnotherCallMakesTheCatchAPath :: control :: M-TS-DEADCATCH-ANY-CALL',
		'unit.check.ThreadSafetyDeadCatchTest#testTheTryBodyStillRuns :: control :: M-TS-DEADCATCH-BODY',
		'unit.check.ThreadSafetyDominanceTest#testABriefUnresolvedCallLeavesDominanceStanding :: control :: '
			+ 'M-TS-DOM-BRIEF-NAMES-IGNORED,M-TS-DOM-BRIEF-REPEATED',
		'unit.check.ThreadSafetyDominanceTest#testACallOnAnUnresolvedResultIsBlind :: guard :: ',
		'unit.check.ThreadSafetyDominanceTest#testAConditionalTakeTheValuationDecidesCounts :: control :: '
			+ 'M-TS-DOM-UNDECIDED,M-TS-DOM-ENTRY-NONE',
		'unit.check.ThreadSafetyDominanceTest#testAGiveACallbackRunsNowBreaksDominance :: guard :: ',
		'unit.check.ThreadSafetyDominanceTest#testAGiveOfTheOuterLockBeforeTheLongCallBreaksDominance :: control :: '
			+ 'M-TS-DOM-RELEASE-IGNORED',
		'unit.check.ThreadSafetyDominanceTest#testAGiveOfWhatTheFunctionDidNotTakeBreaksDominance :: control :: '
			+ 'M-TS-GIVE-PATH,M-TS-GIVE-OBJECT',
		'unit.check.ThreadSafetyDominanceTest#testAGiveOnAnExitingPathKeepsTheOuterLockHeld :: control :: M-TS-DOM-EXITS-IGNORED',
		'unit.check.ThreadSafetyDominanceTest#testAGiveOnTheWayToTheLongCallBreaksDominance :: control :: '
			+ 'M-TS-LEAVES-CAUGHT-THROW,M-TS-COVER-RETAKE',
		'unit.check.ThreadSafetyDominanceTest#testAGiveRepeatedAfterOneTakeBreaksDominance :: control :: M-TS-GIVE-REPEATED',
		'unit.check.ThreadSafetyDominanceTest#testAHoldDominatesItsOwnTake :: control :: M-TS-DOM-UNDER-HOLD-OFF,M-TS-RUNS-AS-IS',
		'unit.check.ThreadSafetyDominanceTest#testALongHoldOutsideTheOuterLockBreaksDominance :: control :: M-TS-DOM-ANY-HOLD',
		'unit.check.ThreadSafetyDominanceTest#testAMainTakeUnderTheOuterLockIsBrief :: control :: M-TS-DOM-OFF',
		'unit.check.ThreadSafetyDominanceTest#testAnOpenWorldCalleeHoldsNothingOnEntry :: control :: M-TS-MEET-OUTSIDE',
		'unit.check.ThreadSafetyDominanceTest#testAnotherObjectsLockIsNotDominated :: control :: M-TS-DOM-ANY-OBJECT',
		'unit.check.ThreadSafetyDominanceTest#testExplainLongNamesTheDominatedLock :: control :: M-TS-DOM-EXPLAIN-DROPPED',
		'unit.check.ThreadSafetyDominanceTest#testOnlyAnOwnedExclusiveLockDominates :: control :: M-TS-DOM-OWNERLESS,M-TS-DOM-SHARED',
		'unit.check.ThreadSafetyEnclosedHoldTest#testAGiveOnTheCallersWayBreaksTheEnclosure :: control :: '
			+ 'M-TS-RELEASE-CALLBACK,M-TS-BLIND-START',
		'unit.check.ThreadSafetyEnclosedHoldTest#testAHoldEveryCallerEnclosesIsTheirs :: control :: M-TS-ENCLOSED-OFF',
		'unit.check.ThreadSafetyEnclosedHoldTest#testASilencedHoldEnclosesNothing :: control :: M-TS-ENCLOSED-SUPPRESSED',
		'unit.check.ThreadSafetyEnclosedHoldTest#testOneCallerOutsideTheLockKeepsItsOwn :: control :: M-TS-ENCLOSED-ANY-STATE',
		'unit.check.ThreadSafetyEnclosedHoldTest#testTheNoteNamesTheEnclosingWarning :: control :: M-TS-ENCLOSED-NOTE',
		'unit.check.ThreadSafetyErrorPathTest#testABlockAlsoOutsideTheCatchWarns :: control :: M-TS-ERROR-ANY,M-TS-ERROR-TAKE-ANY',
		'unit.check.ThreadSafetyErrorPathTest#testABlockInTheHoldsOwnCatchIsInfo :: control :: M-TS-ERROR-WINDOW-OFF',
		'unit.check.ThreadSafetyErrorPathTest#testABlockOnlyInACalleesCatchIsInfo :: control :: '
			+ 'M-TS-ERROR-REACH-OFF,M-TS-ERROR-HOLD-OFF,M-TS-ERROR-TAKE-OFF',
		'unit.check.ThreadSafetyErrorPathTest#testACatchARepeatingCallerRunsIsNoErrorPath :: control :: M-TS-ERROR-REPEATED-WAY',
		'unit.check.ThreadSafetyErrorPathTest#testACatchInALoopIsNoErrorPath :: control :: M-TS-ERROR-LOOP',
		'unit.check.ThreadSafetyErrorPathTest#testALambdaACatchStoresRunsAnywhere :: control :: '
			+ 'M-TS-ERROR-NESTED-REF,M-TS-ERROR-CALLED-LOCAL',
		'unit.check.ThreadSafetyErrorPathTest#testAMainSinkCallInACatchARepeatingCallerRunsWarns :: control :: M-TS-ERROR-CAUGHT-REPEATED',
		'unit.check.ThreadSafetyErrorPathTest#testAMainSinkCallInACatchIsInfo :: control :: M-TS-ERROR-CAUGHT-OFF',
		'unit.check.ThreadSafetyErrorPathTest#testExplainLongMarksTheErrorPath :: control :: M-TS-ERROR-EXPLAIN-OFF',
		'unit.check.ThreadSafetyExhaustiveTest#testACatchAllNoValueReachesIsNoPathInAStatement :: control :: M-TS-EXH-STRUCT',
		'unit.check.ThreadSafetyExhaustiveTest#testACatchAllNoValueReachesIsNoPathInAValue :: control :: M-TS-EXH-OFF,M-TS-EXH-OPAQUE',
		'unit.check.ThreadSafetyExhaustiveTest#testAFromClauseOpensTheAbstract :: control :: M-TS-EXH-FROM',
		'unit.check.ThreadSafetyExhaustiveTest#testAFunctionBuildingAnyValueOpensTheAbstract :: control :: M-TS-EXH-FROMFN',
		'unit.check.ThreadSafetyExhaustiveTest#testAGetterReturningItsOwnFieldHoldsWhatTheFieldHolds :: control :: M-TS-EXH-ISVAR-SELF',
		'unit.check.ThreadSafetyExhaustiveTest#testAGuardedCaseNamesNoValue :: control :: M-TS-EXH-GUARD',
		'unit.check.ThreadSafetyExhaustiveTest#testAParameterHoldsValuesOnlyWhereEveryCallHandsOne :: control :: '
			+ 'M-TS-EXH-PARAM-CALLERS,M-TS-EXH-PARAM-REF',
		'unit.check.ThreadSafetyExhaustiveTest#testARunThatMayMissAWriteReadsNoMemberAsHoldingValues :: control :: M-TS-EXH-PARTIAL',
		'unit.check.ThreadSafetyExhaustiveTest#testASubjectTheFunctionBindsIsNoMember :: control :: M-TS-EXH-SUBJECT-BOUND',
		'unit.check.ThreadSafetyExhaustiveTest#testAValueNoCaseNamesReachesIt :: control :: M-TS-EXH-ALL-NAMED',
		'unit.check.ThreadSafetyExhaustiveTest#testAWriteElsewhereWritesTheMemberOnlyWhereItMay :: control :: M-TS-EXH-WRITES-ANY',
		'unit.check.ThreadSafetyExhaustiveTest#testAnAbstractNameDeclaredTwiceIsNotRead :: control :: M-TS-EXH-COLLISION',
		'unit.check.ThreadSafetyExhaustiveTest#testMembersBuildingOtherValuesOpenTheAbstract :: control :: '
			+ 'M-TS-EXH-FROM,M-TS-EXH-CTOR,M-TS-EXH-NORET',
		'unit.check.ThreadSafetyExhaustiveTest#testTheMemberHoldsOnlyValues :: control :: '
			+ 'M-TS-EXH-WRITES,M-TS-EXH-UNINIT,M-TS-EXH-ZERO,M-TS-EXH-OPTIONAL',
		'unit.check.ThreadSafetyExhaustiveTest#testValuesThroughAccessorsAndConversions :: control :: '
			+ 'M-TS-EXH-CONVERT-OFF,M-TS-EXH-CONVERT-ANY',
		'unit.check.ThreadSafetyFactsTest#testCompilerFactsResolveWhatTheSyntaxCannot :: control :: '
			+ 'M-TS-FACTS-IGNORED,M-TS-FACTS-MADE-REF,M-TS-FACTS-GATE',
		'unit.check.ThreadSafetyFindingDataTest#testALongCallALoopRepeatsSaysWhichLoop :: control :: '
			+ 'M-TS-REPEATED-BY-OFF,M-TS-REPEATED-BY-SELF',
		'unit.check.ThreadSafetyFindingDataTest#testInitializerFindingsNameTheInitializer :: control :: M-TS-DATA-INIT-LAMBDA',
		'unit.check.ThreadSafetyFindingDataTest#testKeysAndMessagesDoNotDependOnOtherCode :: control :: '
			+ 'M-TS-HAND-RANK,M-TS-REPEATED-BY-HEADER',
		'unit.check.ThreadSafetyFindingDataTest#testLambdaFindingNamesItsEnclosingMember :: control :: M-TS-DATA-MEMBER-LAMBDA',
		'unit.check.ThreadSafetyFindingDataTest#testLockOrderData :: control :: M-TS-DATA-SUBJECT-UNSORTED',
		'unit.check.ThreadSafetyFindingDataTest#testLockOrderKeyIgnoresWalkOrder :: control :: M-TS-ORDER-ONE-ARRIVAL',
		'unit.check.ThreadSafetyFindingDataTest#testLockOrderKeySurvivesARenameOutsideIt :: control :: '
			+ 'M-TS-ORDER-CLIMB-FIRST,M-TS-ORDER-ONE-ARRIVAL',
		'unit.check.ThreadSafetyFindingDataTest#testLockOrderNamesTheLeastHolder :: control :: M-TS-ORDER-MAIN-FIRST-SEEN',
		'unit.check.ThreadSafetyFindingDataTest#testMainSinkDataCarriesTheWholeChain :: control :: M-TS-DATA-CHAIN-CAPPED',
		'unit.check.ThreadSafetyFindingDataTest#testSeveralSinksAreOneSortedSubject :: control :: M-TS-DATA-SUBJECT-UNSORTED',
		'unit.check.ThreadSafetyFindingDataTest#testTheLockWarningCarriesWhatRepeatsItsFoldedTakes :: control :: M-TS-ONE-TAKE-MERGE',
		'unit.check.ThreadSafetyFindingDataTest#testTheWayWarningCarriesWhatRepeatsItsFoldedCalls :: control :: M-TS-REPEATED-BY-MERGE',
		'unit.check.ThreadSafetyFindingDataTest#testThrowHeldDataFollowsTheRaiser :: control :: M-TS-DATA-RAISER-CHAIN',
		'unit.check.ThreadSafetyFoldingTest#testAFunctionOnlyASinkCallsIsTheSinks :: control :: M-TS-INSIDE-SINK-DIRECT-ONLY',
		'unit.check.ThreadSafetyFoldingTest#testAHoldInsideAnotherIsItsFinding :: control :: M-TS-NEST-OFF',
		'unit.check.ThreadSafetyFoldingTest#testAWaitInsideASinksBodyIsTheSinks :: control :: M-TS-INSIDE-SINK-OFF',
		'unit.check.ThreadSafetyFoldingTest#testMainTakesOfOneLockWarnOnce :: control :: M-TS-ONE-TAKE-OFF,M-TS-ONE-TAKE-NO-WRAPPER',
		'unit.check.ThreadSafetyHandedValueTest#testADirectCallOutranksAHandedValue :: control :: '
			+ 'M-TS-WAY-HANDED-RANK,M-TS-OWNER-HANDED-RANK',
		'unit.check.ThreadSafetyHandedValueTest#testAFieldItsTypeDeclarationExposesIsNotOnlyStored :: control :: '
			+ 'M-TS-STORED-HOLDER-NOT-DECLARATION',
		'unit.check.ThreadSafetyHandedValueTest#testAFieldTheLanguageCallsByNameIsNotOnlyStored :: control :: '
			+ 'M-TS-STORED-IMPLICIT-NAME,M-TS-STORED-PUBLIC',
		'unit.check.ThreadSafetyHandedValueTest#testAHandedValueRepeatsWithTheCallItIsHandedTo :: control :: '
			+ 'M-TS-REPEAT-NO-ITERATES,M-TS-RUNS-ONCE-OFF',
		'unit.check.ThreadSafetyHandedValueTest#testAHoldTaintsAValueHandedToACallThatRunsIt :: control :: '
			+ 'M-TS-HANDED-RUNS-HERE,M-TS-HANDED-WINDOW-OFF,M-TS-HANDED-REACH-OFF,M-TS-HANDED-SINK-OFF',
		'unit.check.ThreadSafetyHandedValueTest#testALockTakenInAHandedValueOrdersUnderTheHold :: control :: M-TS-ORDER-HANDED,'
			+ 'M-TS-ORDER-HANDED-ANYWHERE,M-TS-ORDER-FOLLOWS-REFS,M-TS-ORDER-HANDED-RANK,M-TS-ORDER-HANDED-CLIMB,M-TS-ORDER-HANDED-VIA',
		'unit.check.ThreadSafetyHandedValueTest#testAMainSinkHandedAsAValueIsReported :: control :: M-TS-HANDED-SINK-OFF',
		'unit.check.ThreadSafetyHandedValueTest#testAMethodValueOfAnotherObjectWaitsForItsLock :: control :: M-TS-HANDED-RETAKE',
		'unit.check.ThreadSafetyHandedValueTest#testAValueAConstructorOnlyStoresRunsWhereTheFieldIsCalled :: control :: '
			+ 'M-TS-CTOR-STORE-INERT,M-TS-CTOR-STORE-DERIVE,M-TS-CTOR-STORE-FINAL,M-TS-CTOR-STORE-READS,M-TS-CTOR-STORE-FORWARD,'
			+ 'M-TS-CTOR-STORE-CLOSED,M-TS-CTOR-STORE-SPELLED,M-TS-CTOR-STORE-STATEMENT,M-TS-CTOR-STORE-USE',
		'unit.check.ThreadSafetyHandedValueTest#testAValueRunElsewhereTaintsNothing :: control :: '
			+ 'M-TS-HANDED-ELSEWHERE,M-TS-CYCLE-REGISTERED',
		'unit.check.ThreadSafetyHelperHoldsTest#testACallAGiveIsMadeOnIsWorkOfTheHelper :: control :: M-TS-HELPER-SPAN-START',
		'unit.check.ThreadSafetyHelperHoldsTest#testAHandedOffHoldIsNoInnerHold :: control :: M-TS-NEST-HANDOFF',
		'unit.check.ThreadSafetyHelperHoldsTest#testAHelperReachedByDispatchIsNone :: control :: M-TS-HELPER-DISPATCH',
		'unit.check.ThreadSafetyHelperHoldsTest#testAHelpersHoldHandedOffByItsCallerIsLong :: control :: M-TS-HELPER-HANDOFF',
		'unit.check.ThreadSafetyHelperHoldsTest#testAHelpersLaterTakeFoldsOntoItsFirst :: control :: M-TS-PAIR-OFF,M-TS-PAIR-ORDER',
		'unit.check.ThreadSafetyHelperHoldsTest#testTheHelpersCallerHoldsBothLocks :: control :: M-TS-HELPER-B-OFF,M-TS-HELPER-OWN-WINDOW',
		'unit.check.ThreadSafetyHelperHoldsTest#testTheHelpersOtherLocksAreHeldToo :: control :: '
			+ 'M-TS-HELPER-SIBLINGS,M-TS-SAME-LOCAL-ROOT,M-TS-HELPER-GIVE-OBJECT',
		'unit.check.ThreadSafetyHelperHoldsTest#testTheHelpersWaitForItsSecondLockFoldsOntoItsHolders :: control :: '
			+ 'M-TS-FOLD-HELPER-CROSSING,M-TS-FOLD-STUCK-WAIT,M-TS-FOLD-STUCK-MADE',
		'unit.check.ThreadSafetyHelperHoldsTest#testTheTwinsGiveIsNoCrossingRelease :: control :: M-TS-HELPER-CROSSING',
		'unit.check.ThreadSafetyHelperHoldsTest#testTheTwinsGiveLeavesDominanceStanding :: control :: M-TS-HELPER-DOM-CROSSING',
		'unit.check.ThreadSafetyHelperHoldsTest#testWorkInsideAGivingHelperIsHeldByItsCaller :: control :: M-TS-HELPER-BODY-WORK',
		'unit.check.ThreadSafetyHelperHoldsTest#testWorkInsideATakingHelperIsJudged :: control :: M-TS-HELPER-BODY-WORK',
		'unit.check.ThreadSafetyLibraryBodiesTest#testALibraryCallThatBlocksInsideIsASink :: control :: '
			+ 'M-TS-LIB-OFF,M-TS-LIB-NOT-SINKS,M-TS-LIB-CHAIN-OFF,M-TS-LIB-NOTICE,M-TS-LIB-KNOWN,M-TS-LIB-AWAY-OFF',
		'unit.check.ThreadSafetyLibraryBodiesTest#testALibraryTheBuildCannotFindIsSaid :: control :: '
			+ 'M-TS-LIB-LOST-LIB-SAID,M-TS-LIB-LOST-CP-SAID',
		'unit.check.ThreadSafetyLibraryBodiesTest#testAProjectTypeRunsNoLibraryOverride :: control :: '
			+ 'M-TS-LIB-VIRTUAL-OFF,M-TS-LIB-PROJECT-OVERRIDES,M-TS-LIB-PROJECT-TYPE',
		'unit.check.ThreadSafetyLibraryBodiesTest#testAnUnknownBuildIsSaid :: control :: M-TS-LIB-UNKNOWN-SAID',
		'unit.check.ThreadSafetyLibraryBodiesTest#testNonBlockingWaivesALibraryNative :: control :: M-TS-LIB-WAIVE-OFF,M-TS-LIB-WAIVE-SAID',
		'unit.check.ThreadSafetyLibraryBodiesTest#testTheLibrariesAreReadAsTheBuildCompilesThem :: control :: '
			+ 'M-TS-LIB-DEFINES-OFF,M-TS-LIB-DASH,M-TS-LIB-ORACLE-DEFINES,M-TS-LIB-TARGET-DEFINES,M-TS-LIB-VERSION-DEFINES,'
			+ 'M-TS-LIB-OTHER-TARGET-FILE,M-TS-LIB-SHADOWED,M-TS-LIB-TARGET-PACKAGE',
		'unit.check.ThreadSafetyLongLocksTest#testACircularReTakeIsCountedApart :: control :: M-TS-CIRCULAR-COUNTED',
		'unit.check.ThreadSafetyLongLocksTest#testAShadowedFlagIsNoFixedFlag :: control :: M-TS-FLAGS-SHADOW,M-TS-FLAGS-WRITTEN',
		'unit.check.ThreadSafetyLongLocksTest#testAVirtualCallIsAReasonPerTarget :: control :: M-TS-REASONS-DEDUP-BY-SITE',
		'unit.check.ThreadSafetyLongLocksTest#testAWrittenFlagIsNoFixedFlag :: control :: M-TS-FLAGS-WRITTEN',
		'unit.check.ThreadSafetyLongLocksTest#testAsideNamesTheLongLockAHoldWaitsFor :: control :: M-TS-VIA-DROPPED',
		'unit.check.ThreadSafetyLongLocksTest#testAsideSetsTheLocksOwnReasonsAside :: control :: M-TS-ASIDE-KEEPS-SEEDS',
		'unit.check.ThreadSafetyLongLocksTest#testCorrelatedConditionalTakeIsNoLeak :: control :: M-TS-FLAGS-OFF',
		'unit.check.ThreadSafetyLongLocksTest#testEverySpansBlockingCallIsListed :: control :: M-TS-SPANS-FIRST-ONLY',
		'unit.check.ThreadSafetyLongLocksTest#testMainThreadTakesOfAShortLock :: control :: M-TS-MAINSHORT-LOUD-ONLY',
		'unit.check.ThreadSafetyLongLocksTest#testSpansBlockingNamesTheCallAndThePath :: control :: M-TS-LONG-NEVER-GROWS',
		'unit.check.ThreadSafetyMainOnlyTest#testWorkOwnedByARepeatingCalleeLeavesTheHoldInfo :: control :: M-TS-MAINONLY-MOVED',
		'unit.check.ThreadSafetyMainOnlyTest#testWorkReportedAtACalleeLeavesTheHoldInfo :: control :: M-TS-MAINONLY-ELSEWHERE-OFF',
		'unit.check.ThreadSafetyMainOnlyTest#testWorkReportedAtTheHolderLeavesTheHoldInfo :: control :: M-TS-MAINONLY-ELSEWHERE-OFF',
		'unit.check.ThreadSafetyMainOnlyTest#testWorkReportedOnlyBySilencedFindingsKeepsTheHold :: control :: M-TS-REPORTED-SUPPRESSED',
		'unit.check.ThreadSafetyMainStatesTest#testAConstantArgumentRulesTheRepeatedCallOut :: control :: M-TS-STATES-IGNORED',
		'unit.check.ThreadSafetyMainStatesTest#testALiteralArgumentDecidesAFinalLocalCondition :: control :: '
			+ 'M-TS-COND-FINAL-LOCAL,M-TS-ARG-LITERAL-NONNULL,M-TS-ARG-FINAL-LOCAL-READ',
		'unit.check.ThreadSafetyMainStatesTest#testTheOwnerIsOnAWayThatRunsTheCall :: control :: M-TS-STATES-OWNER-IGNORED',
		'unit.check.ThreadSafetyOptionsTest#testALostSinksListIsSaid :: control :: '
			+ 'M-TS-OPT-SINKS-UNMATCHED,M-TS-OPT-SKIP-DECLARED,M-TS-OPT-NO-SINK-NOTICES,M-TS-OPT-LIFTED,M-TS-OPT-SINKS-ENTRY-UNMATCHED',
		'unit.check.ThreadSafetyOptionsTest#testEveryMalformedOptionIsSaid :: control :: M-TS-OPT-UNKNOWN,M-TS-OPT-LIST-SHAPE,'
			+ 'M-TS-OPT-LIST-ITEM,M-TS-OPT-FLAG,M-TS-OPT-BUDGET,M-TS-OPT-BOUNDED-ENTRY,M-TS-OPT-BOUNDED-SITE',
		'unit.check.ThreadSafetyOwnReasonsTest#testABriefUnresolvedCallOnceLeavesTheLockShort :: control :: '
			+ 'M-TS-BLIND-BRIEF-OFF,M-TS-DOM-BRIEF-NAMES-IGNORED',
		'unit.check.ThreadSafetyOwnReasonsTest#testACallOfAReleaserGivesTheLockBack :: control :: M-TS-HANDOFF-CROSSING',
		'unit.check.ThreadSafetyOwnReasonsTest#testAHoldItsFunctionNeverGivesBackIsLong :: control :: M-TS-HANDOFF-OFF,M-TS-HANDOFF-GIVES',
		'unit.check.ThreadSafetyOwnReasonsTest#testARepeatedOrUnknownUnresolvedCallKeepsTheLockLong :: control :: M-TS-DOM-BRIEF-REPEATED',
		'unit.check.ThreadSafetyOwnReasonsTest#testAnUnresolvedCallInACatchIsAnErrorPath :: control :: M-TS-BLIND-CATCH-OFF',
		'unit.check.ThreadSafetyPositiveSinksTest#testADottedWaiverNamesOnlyTheTypeAtThatPath :: control :: M-TS-DOTTED-WILDCARD',
		'unit.check.ThreadSafetyPositiveSinksTest#testALibraryTypeIsNotItsProjectNamesake :: control :: M-TS-PATH-FOREIGN,'
			+ 'M-TS-PATH-RECEIVER-STATIC,M-TS-PATH-NEW,M-TS-PATH-MATCH,M-TS-SHADOWING-KEPT,M-TS-PATH-NOMINAL,M-TS-ALIAS-TYPE',
		'unit.check.ThreadSafetyPositiveSinksTest#testALocalOfACallResultIsTypedByWhatTheCallReturns :: control :: '
			+ 'M-NOMINAL-LOCAL-INIT,M-TS-LOCAL-CALL-READ',
		'unit.check.ThreadSafetyPositiveSinksTest#testAStdLockWrittenInADeclarationWaitsWhereverItIsRead :: control :: '
			+ 'M-TS-DECL-MEMBER-FILE,M-TS-ALTERNATE-WHOLE-CALL',
		'unit.check.ThreadSafetyPositiveSinksTest#testAStdMemberStandsWhereEveryNamesakeAgrees :: control :: '
			+ 'M-TS-STD-AGREE,M-TS-STD-SUPER,M-TS-STD-SIBLING',
		'unit.check.ThreadSafetyPositiveSinksTest#testAWildcardOrGuardedImportOfALibraryTypeIsNotItsProjectNamesake :: control :: '
			+ 'M-TS-WILD-PACKAGES,M-TS-WILD-OWN-MODULE,M-TS-WILD-EXPLICIT-FIRST,M-TS-WILD-STD,M-TS-GUARDED-IMPORT,M-TS-ALTERNATE-CALL',
		'unit.check.ThreadSafetyPositiveSinksTest#testNonBlockingWaivesOnEvidence :: control :: '
			+ 'M-TS-WAIVE-OFF,M-TS-WAIVE-SAYS-NOTHING,M-TS-WAIVE-SINKS-WIN,M-TS-OPT-NONBLOCKING-EVIDENCE',
		'unit.check.ThreadSafetyPositiveSinksTest#testProjectNativesBlock :: control :: '
			+ 'M-TS-NATIVE-EXTERN,M-TS-NATIVE-EXTERN-ANY-BODYLESS,M-TS-NATIVE-META,M-TS-NATIVE-LOADER,M-TS-NATIVE-AFFIX,'
			+ 'M-TS-NATIVE-CALLEE-SPAN,M-TS-NATIVE-CODE-CALLS,M-TS-NATIVE-LOADED-MEMBER',
		'unit.check.ThreadSafetyPositiveSinksTest#testStdResultsTypeTheirReceivers :: control :: '
			+ 'M-TS-STD-RETURN,M-TS-STD-FIELD,M-TS-STD-GETTER,M-TS-STD-GETTER-LOCAL,M-TS-STD-GETTER-TYPED,M-TS-NEW-RECEIVER,'
			+ 'M-TS-ALIAS-TYPE,M-TS-STD-PLACEHOLDER,M-TS-BUILTIN-EVENTS,M-TS-PATH-IMPORT',
		'unit.check.ThreadSafetyPositiveSinksTest#testTheBuiltinAppliesWithNoSinks :: control :: '
			+ 'M-TS-REPORT-NEEDS-SINKS,M-TS-BUILTIN-OFF,M-TS-BUILTIN-ANY-NODE',
		'unit.check.ThreadSafetyPositiveSinksTest#testTheNoticeCountsWhatNonBlockingRemoved :: control :: M-TS-NOTICE-WAIVED',
		'unit.check.ThreadSafetyPositiveSinksTest#testTheRunSaysWhichBuiltinsApplied :: control :: M-TS-BUILTIN-NOTICE-OFF',
		'unit.check.ThreadSafetyQuietLocksTest#testAConstructorsOwnTakeNeverWaits :: control :: M-TS-CTOR-TAKE',
		'unit.check.ThreadSafetyQuietLocksTest#testALockOnlyTakenSharedNeverWaits :: control :: M-TS-SHARED-OFF,M-TS-SHARED-HOLD',
		'unit.check.ThreadSafetyQuietLocksTest#testAnExclusiveTakeMakesTheSharedOnesWait :: control :: M-TS-SHARED-ANY',
		'unit.check.ThreadSafetyReflectiveSealTest#testACaptureIsTypedThroughItsSubject :: control :: '
			+ 'M-TS-BINDER-SUBJECT,M-TS-BINDER-PLACED-BY,M-TS-BINDER-TOP,M-TS-BINDER-OWN-PARAMS',
		'unit.check.ThreadSafetyReflectiveSealTest#testAFreshObjectReceiverKeepsTheLockNames :: control :: '
			+ 'M-TS-PLACE-FRESH-STRUCT,M-TS-PLACE-FRESH-NEW,M-TS-PLACE-FRESH-MUTABLE',
		'unit.check.ThreadSafetyReflectiveSealTest#testALockAReflectiveWriteUnsealsSaysWhoUnsealedIt :: control :: '
			+ 'M-TS-UNSEALED-NOTE,M-TS-UNSEALED-HOLDS,M-TS-UNSEALED-PRECONDITIONS,M-TS-UNSEALED-TAKE,M-TS-UNSEALED-THROW',
		'unit.check.ThreadSafetyReflectiveSealTest#testAParameterIsFollowedOnlyWhereEveryCallIsSeen :: control :: '
			+ 'M-TS-STORED-CALLERS,M-TS-STORED-HOLDERS,M-TS-STORED-SPELLED,M-TS-STORED-GLOB,M-TS-STORED-SKIPPED,M-TS-STORED-REF',
		'unit.check.ThreadSafetyReflectiveSealTest#testAParameterItsFunctionWritesHoldsWhatEveryWriteStores :: control :: '
			+ 'M-TS-STORED-WRITTEN,M-TS-STORED-WRITE-VALUE,M-TS-STORED-WRITE-OPERATOR,M-TS-STORED-WRITE-OTHER',
		'unit.check.ThreadSafetyReflectiveSealTest#testAStructureTypedefMayHoldALock :: control :: M-TS-ENUM-KIND',
		'unit.check.ThreadSafetyReflectiveSealTest#testATypeParameterNamedLikeAClassIsNoneOfIt :: control :: '
			+ 'M-TS-STORED-TYPE-PARAM,M-TS-SCOPE-TYPE-PARAMS,M-TS-SCOPE-FUNCTION-PARAMS',
		'unit.check.ThreadSafetyReflectiveSealTest#testATypeParameterReceiverIsBoundedByItsInstantiations :: control :: '
			+ 'M-TS-PLACE-INSTANTIATIONS,M-TS-PLACE-COMPLETE,M-TS-PLACE-RAW-LINK,M-TS-PLACE-FREE-SUB,M-TS-PLACE-NEVER-MADE,'
			+ 'M-TS-PLACE-UNDECLARED,M-TS-PLACE-GLOB-MATCH,M-TS-PLACE-MAKES-NEW,M-TS-PLACE-MAKES-VALUE,M-TS-PLACE-MAKES-RECEIVER,'
			+ 'M-TS-PLACE-VOID,M-TS-PLACE-FORWARDED-BOUND,M-TS-PLACE-PARAM-CONSTRAINT,M-TS-PLACE-PARAM-OWNER,M-TS-FINAL-SUPERS-WRITTEN,'
			+ 'M-TS-PATH-DECLARED-PACKAGE',
		'unit.check.ThreadSafetyReflectiveSealTest#testAValueTheRunCannotPlaceUnsealsEveryLock :: control :: '
			+ 'M-TS-SEAL-REFLECT-UNPLACED,M-TS-SEAL-UNPLACED-NOTICE,M-TS-BINDER-TYPE,M-TS-STORED-COMPLETE',
		'unit.check.ThreadSafetyReflectiveSealTest#testAWriteThatMayStoreALockUnsealsAsBefore :: control :: '
			+ 'M-TS-STORED-ANY,M-TS-STORED-RELATED,M-TS-STORED-ARGUMENTS',
		'unit.check.ThreadSafetyReflectiveSealTest#testAWriteThatStoresNoLockKeepsTheLockNames :: control :: '
			+ 'M-TS-STORED-NOTHING,M-TS-STORED-LITERAL,M-TS-STORED-NULL,M-TS-STORED-TYPED,M-TS-STORED-UNRELATED,M-TS-STORED-PARAMETER,'
			+ 'M-TS-STORED-KEPT-NOTICE,M-TS-STORED-COUNTS,M-TS-STORED-ENUM,M-TS-STORED-BASIC,M-TS-STORED-CATCH-ALL',
		'unit.check.ThreadSafetyReflectiveSealTest#testAnUncheckedCastIsNoDeclaredType :: control :: '
			+ 'M-TS-STORED-CAST-LOCAL,M-TS-STORED-CAST-FIELD,M-TS-STORED-CAST-KINDS,M-TS-STORED-CAST-DYNAMIC,M-TS-STORED-CAST-WRITES',
		'unit.check.ThreadSafetyReflectiveSealTest#testEveryNameThatMakesTheClassMakesIt :: control :: '
			+ 'M-TS-MAKES-RESOLVED,M-TS-MAKES-LITERAL,M-TS-MAKES-UNKNOWN,M-TS-MAKES-STD,M-TS-MAKES-ALIAS-NOTHING,M-TS-MAKES-ALIAS-STD,'
			+ 'M-TS-MAKES-WILD,M-TS-MAKES-BOUND,M-TS-MAKES-USING',
		'unit.check.ThreadSafetyReflectiveSealTest#testWhatAWriteStoresUnsealsOnlyTheLocksOfItsType :: control :: '
			+ 'M-TS-STORED-MEMBER-TYPE,M-TS-STORED-MARKED,M-TS-STORED-TYPED-NOTICE',
		'unit.check.ThreadSafetyRegistersTest#testALoopAboveTheRegistrarRepeatsNothing :: control :: M-TS-REGISTER-OWNER',
		'unit.check.ThreadSafetyRegistersTest#testAProjectMemberEntryRegisters :: control :: M-TS-REGISTER-MEMBER',
		'unit.check.ThreadSafetyRegistersTest#testARegistrationInALoopRepeatsNothing :: control :: M-TS-REGISTER-OWNER',
		'unit.check.ThreadSafetyRegistersTest#testTheOwnerIsNeverUpARegistration :: control :: M-TS-REGISTER-OWNER',
		'unit.check.ThreadSafetyRepetitionTest#testABareRunsOnceNameSaysNothingOfProjectCode :: control :: '
			+ 'M-TS-RUNS-ONCE-PROJECT,M-TS-RUNS-ONCE-UNRESOLVED',
		'unit.check.ThreadSafetyRepetitionTest#testAFunctionNoResolvedCallRunsWarns :: control :: M-TS-ASSUMED-OFF',
		'unit.check.ThreadSafetyRepetitionTest#testAHandedValueIsKeyedByTheCall :: control :: M-TS-HAND-SUBJECT',
		'unit.check.ThreadSafetyRepetitionTest#testALoopWarningIsKeyedByItsHeader :: control :: M-TS-LOOP-SUBJECT',
		'unit.check.ThreadSafetyRepetitionTest#testAMarshalledValueRepeats :: control :: M-TS-MARSHAL-OWNER-OFF',
		'unit.check.ThreadSafetyRepetitionTest#testARegistrationIntoProjectCodeRepeats :: control :: M-TS-REGISTER-PROJECT',
		'unit.check.ThreadSafetyRepetitionTest#testARunsOnceCallRepeatsNothing :: control :: M-TS-RUNS-ONCE-OFF',
		'unit.check.ThreadSafetyRepetitionTest#testARuntimeRegistrationIsOncePerEvent :: control :: M-TS-SHORT-REGISTERED-NOTE',
		'unit.check.ThreadSafetyRepetitionTest#testAStaticInitializerRunsOnce :: control :: M-TS-ASSUMED-STATIC',
		'unit.check.ThreadSafetyRepetitionTest#testAValueHandedToAnUnlistedCallRepeats :: control :: M-TS-REPEAT-NO-ITERATES',
		'unit.check.ThreadSafetyRepetitionTest#testEquallyNearOwnersEachWarn :: control :: M-TS-OWNER-FIRST-ONLY',
		'unit.check.ThreadSafetyRepetitionTest#testOwnersAreOrderedByOffsetAsANumber :: control :: M-TS-OWNER-OFFSET-TEXT',
		'unit.check.ThreadSafetyRethrowTest#testACatchThatRethrowsRaises :: control :: M-TS-RETHROW-OFF',
		'unit.check.ThreadSafetyRethrowTest#testACatchThrowingAnyValueRaises :: control :: M-TS-RETHROW-ANY-NAME',
		'unit.check.ThreadSafetyRethrowTest#testARethrowInANestedFunctionKeepsIt :: control :: M-TS-RETHROW-NESTED',
		'unit.check.ThreadSafetyRethrowTest#testATypedCatchLetsAThrowersExceptionThrough :: control :: '
			+ 'M-TS-THROW-TYPED-INTERCEPTS,M-TS-CATCH-ANY-TYPE',
		'unit.check.ThreadSafetyRootCauseTest#testACallIsCoveredOnlyWhenEveryBlockingCallItReachesIs :: control :: '
			+ 'M-TS-FOLD-EVERY-END,M-TS-FOLD-ENDS-WALK,M-TS-FOLD-PASSES-PATH,M-TS-FOLD-NAMED-ONLY,M-TS-FOLD-UNNAMED-NOTE',
		'unit.check.ThreadSafetyRootCauseTest#testACallOnlyACatchRunsLeavesTheFoldStanding :: control :: M-TS-FOLD-NORMAL',
		'unit.check.ThreadSafetyRootCauseTest#testACallUnderARecursiveWalkRepeats :: control :: M-TS-FOLD-SITE-CYCLE,M-TS-CYCLE-REF',
		'unit.check.ThreadSafetyRootCauseTest#testAHoldLongOnlyByWaitingForAWarnedHolderIsInfo :: control :: M-TS-FOLD-OFF',
		'unit.check.ThreadSafetyRootCauseTest#testAHoldReachingACallOnceCoversNoRepeatingOne :: control :: M-TS-FOLD-SITE-ONCE',
		'unit.check.ThreadSafetyRootCauseTest#testAHoldTurnedOntoAnInfoFindingSaysSo :: control :: M-TS-COVER-INFO-NOTE',
		'unit.check.ThreadSafetyRootCauseTest#testALockReleasedElsewhereLeavesTheWaiterWarned :: control :: M-TS-FOLD-CROSSING',
		'unit.check.ThreadSafetyRootCauseTest#testARecursionThroughACallbackRepeatsUnderTheLock :: control :: M-TS-CYCLE-REGISTERED',
		'unit.check.ThreadSafetyRootCauseTest#testASuppressedWarningCoversNothing :: control :: '
			+ 'M-TS-FOLD-SUPPRESSED,M-TS-FOLD-SUPPRESSED-WAIT,M-TS-NEST-SUPPRESSED,M-TS-WAY-SUPPRESSED,M-TS-ONE-TAKE-SUPPRESSED',
		'unit.check.ThreadSafetyRootCauseTest#testHoldsLongByOneCallMakeOneWarning :: control :: '
			+ 'M-TS-FOLD-SITE,M-TS-FOLD-DEPTH,M-TS-FOLD-SITE-LOCK',
		'unit.check.ThreadSafetyRootCauseTest#testHoldsOfOneLockInTwoFunctionsAreTwoStalls :: control :: M-TS-FOLD-SITE-LOCK',
		'unit.check.ThreadSafetyRootCauseTest#testHoldsOfTwoLocksOneAfterTheOtherAreTwoStalls :: control :: M-TS-FOLD-NEST-LOCK',
		'unit.check.ThreadSafetyRootCauseTest#testSinkCallsOfOneWayMakeOneWarning :: control :: M-TS-WAY-OFF',
		'unit.check.ThreadSafetyRootCauseTest#testTheCallsOfOneLoopMakeOneWarning :: control :: M-TS-LOOP-KEY',
		'unit.check.ThreadSafetyRootCauseTest#testTwoCallsReachingOneSinkAreTwoWays :: control :: M-TS-FOLD-SAME-WAY,M-TS-FOLD-PARTS-ONCE',
		'unit.check.ThreadSafetyRootCauseTest#testTwoTakesSharingAFindingDoNotCoverEachOther :: control :: M-TS-FOLD-SELF',
		'unit.check.ThreadSafetyRootCauseTest#testUnnamedLocksNeverCoverEachOther :: control :: M-TS-FOLD-UNNAMED-SAME',
		'unit.check.ThreadSafetySpawnArgumentsTest#testAMainArgumentRepeatsPerPost :: control :: M-TS-SPAWN-MAIN-REPEAT',
		'unit.check.ThreadSafetySpawnArgumentsTest#testAMainArgumentRunsOnTheMainThread :: control :: '
			+ 'M-TS-SPAWN-MAIN-ARG,M-TS-SPAWN-MAIN-CONTEXT,M-TS-SPAWN-ARG-POSITION',
		'unit.check.ThreadSafetySpawnArgumentsTest#testAMalformedObjectEntryIsSaid :: control :: M-TS-OPT-SPAWN-OBJECT',
		'unit.check.ThreadSafetySpawnArgumentsTest#testAPositionAnOptionalMayShiftRunsAsThePlainEntry :: control :: M-TS-SPAWN-MAIN-SHIFT',
		'unit.check.ThreadSafetySpawnArgumentsTest#testAnOverloadedCallRunsAsThePlainEntry :: control :: M-TS-SPAWN-MAIN-SIGNATURE',
		'unit.check.ThreadSafetyUnnamedLockTest#testAnUnnamedLockNoMainThreadTakesStallsNoOne :: control :: M-TS-UNNAMED-PAIR',
		'unit.check.ThreadSafetyUnnamedLockTest#testAnotherPairOfTheSameClassStallsTheMainThread :: control :: M-TS-UNNAMED-BY-PAIR',
		'unit.check.ThreadSafetyWaiterTest#testAHoldOnlyTheMainThreadRunsIsNoStall :: control :: '
			+ 'M-TS-B-MAIN-ONLY-KEPT,M-TS-OWN-WORK-TAKES',
		'unit.check.ThreadSafetyWaiterTest#testAHolderOfUnknownThreadKeepsItsFinding :: control :: M-TS-B-ASSUMED-IGNORED',
		'unit.check.ThreadSafetyWaiterTest#testAMainOnlyHoldOverItsOwnLongWorkStays :: control :: M-TS-OWN-WORK-DROPPED',
		'unit.check.ThreadSafetyWindowTest#testAComprehensionIsWalkedAsALoop :: control :: M-TS-WIN-ARRAY,M-TS-WIN-FOREXPR',
		'unit.check.ThreadSafetyWindowTest#testAContinueStaysInTheLoop :: control :: M-TS-WIN-JUMP',
		'unit.check.ThreadSafetyWindowTest#testAThrowACatchInterceptsStaysInTheFunction :: control :: M-TS-WIN-CAUGHT-THROW',
		'unit.check.ThreadSafetyWindowTest#testATryInADeclarationReleasingBeforeItRethrowsLeavesNothingHeld :: control :: M-TS-WIN-DECL',
		'unit.check.ThreadSafetyWindowTest#testATypedCatchLetsAnotherThrowThrough :: control :: '
			+ 'M-TS-CATCH-ANY-TYPE,M-TS-CATCH-SUPERTYPE,M-TS-CATCH-EXCEPTION-TYPE',
		'unit.check.TrivialGetterCheckTest#testBasicBlockBodyFlagged :: control :: M-SUBOVERRIDE-TRUE',
		'unit.check.TrivialGetterShapeCollapseTest#testForeignHierarchyBackingNameStaysAccountedFor :: control :: M-SUPERDECLARES-FALSE',
		'unit.check.TrivialGetterShapeCollapseTest#testShapeACtorInitInertDollarSegmentMoveFix :: control :: '
			+ 'M-TRIVGET-INERT-SEGMENT-IGNORED',
		'unit.check.TrivialGetterShapeCollapseTest#testShapeACtorInitNegativeNumberMoveFix :: control :: M-TRIVGET-NO-NEGATION-DESCENT',
		'unit.check.TrivialGetterShapeCollapseTest#testShapeACtorInitSingleQuotedStringMoveFix :: control :: '
			+ 'M-TRIVGET-MOVABLE-LITERAL-FALSE',
		'unit.check.TypeParamShadowTest#testExplicitTypeOracleKeepsAPathAMethodTypeParameterShadows :: control :: M-PRINTER-TYPE-PARAM-BLIND',
		'unit.check.TypeParamShadowTest#testShortenTypeRefKeepsAPathAClassTypeParameterShadows :: control :: M-PRINTER-TYPE-PARAM-BLIND',
		'unit.check.TypeParamShadowTest#testShortenTypeRefKeepsAPathAMethodTypeParameterShadows :: control :: M-PRINTER-TYPE-PARAM-BLIND',
		'unit.check.TypedEventConstantCheckTest#testAConstantNeverUsedAsAnEventTypeIsNotReported :: control :: M-EVENT-NO-USE-GATE',
		'unit.check.TypedEventConstantCheckTest#testAConstantOfAClassThatIsNoEventIsNotReported :: control :: M-EVENT-NO-BASE-GATE',
		'unit.check.TypedEventConstantCheckTest#testAConstructorOfANonEventClassIsNoUse :: control :: '
			+ 'M-EVENT-ANY-NEW-IS-A-USE,M-EVENT-NO-USE-GATE',
		'unit.check.TypedEventConstantCheckTest#testAFunctionTypedLocalListenerIsALatentBug :: control :: M-EVENT-NO-MISMATCH',
		'unit.check.TypedEventConstantCheckTest#testALambdaListenerOfAnotherEventClassIsALatentBug :: control :: M-EVENT-NO-MISMATCH',
		'unit.check.TypedEventConstantCheckTest#testAMethodListenerOfASubclassIsALatentBug :: control :: M-EVENT-NO-MISMATCH',
		'unit.check.TypedEventConstantCheckTest#testAStaticVarIsNoConstant :: control :: M-EVENT-STATIC-VAR',
		'unit.check.TypedEventConstantCheckTest#testAnAbstractWithoutBothStringConversionsMakesTheRuleInert :: control :: '
			+ 'M-EVENT-ABSTRACT-TRUSTED',
		'unit.check.TypedEventConstantCheckTest#testAnEventDispatchedAsAnotherClassIsALatentBug :: control :: M-EVENT-NO-MISMATCH',
		'unit.check.TypedFactsProbeTest#testACallSiteInlineIsASpliceOfItsMethodNotAMacro :: control :: M-FACTS-CALL-SITE-INLINE',
		'unit.check.TypedFactsProbeTest#testAConfigurationThatFailsContributesNothing :: control :: M-FACTS-DROPPED',
		'unit.check.TypedFactsProbeTest#testAConvertedObjectOfExactlyItsClassAndAThrownException :: control :: '
			+ 'M-FACTS-STRING-EXACT,M-FACTS-THROW-EXCEPTION,M-FACTS-EXACT-WRITTEN,M-FACTS-FLOW-EXACT',
		'unit.check.TypedFactsProbeTest#testAFieldReadAnInlinedMethodTakesAsItsReceiverIsTheCallsReceiver :: control :: '
			+ 'M-FACTS-INLINED-RECEIVER,M-FACTS-RECEIVER-BLOCK,M-FACTS-RECEIVER-PARAM',
		'unit.check.TypedFactsProbeTest#testAFieldReadSaysHowItsValueIsUsed :: control :: M-FACTS-USE,M-FACTS-HELD,M-FACTS-CAPTURE',
		'unit.check.TypedFactsProbeTest#testAFieldValueStoredInALocalIsUsedAsTheLocalsReads :: control :: M-FACTS-ASSIGN-HELD,'
			+ 'M-FACTS-ASSIGNED-NO-USE,M-FACTS-ASSIGNED-TARGET,M-FACTS-ALIAS-LINK,M-FACTS-HELD-LOCAL,M-FACTS-SUBSTITUTED-RECEIVER,'
			+ 'M-FACTS-SUBSTITUTED-ARITY,M-FACTS-SUBSTITUTED-OWNER,M-FACTS-ASSIGN-STATEMENT,M-FACTS-ASSIGN-OWNER,M-FACTS-HELD-FLAG',
		'unit.check.TypedFactsProbeTest#testAFileWrittenWhileTheCompileRanIsStale :: control :: '
			+ 'M-FACTS-WRITTEN-DURING,M-FACTS-CHANGED-STALE',
		'unit.check.TypedFactsProbeTest#testALostSplicedFactMarksItsNodeAndOnlyTheStdIsReflection :: control :: '
			+ 'M-FACTS-STALE-FOREIGN,M-FACTS-REFLECTION-PATH',
		'unit.check.TypedFactsProbeTest#testARangeMeetingTheBodyIsItsOwnCode :: control :: M-FACTS-ABSTRACT-THIS',
		'unit.check.TypedFactsProbeTest#testAReflectiveCallRecordsTheLiteralItsNameArgumentHolds :: control :: '
			+ 'M-FACTS-REFL-MEMBER-NAME,M-FACTS-REFL-MEMBER-NAME-ANY,M-FACTS-REFL-MEMBER-NAME-TABLE',
		'unit.check.TypedFactsProbeTest#testAWriteOfAValueBuiltThereAndHandedNowhereIsFresh :: control :: '
			+ 'M-FACTS-FRESH,M-FACTS-FRESH-DISCARDED',
		'unit.check.TypedFactsProbeTest#testAbstractOperatorsConversionsAndAccessorsAreCallsOfTheirImplementations :: control :: '
			+ 'M-FACTS-CALL-TARGET',
		'unit.check.TypedFactsProbeTest#testAnElementWriteIsAWriteThroughTheArrayAtItsOwnRead :: control :: M-FACTS-ELEMENT-WRITE',
		'unit.check.TypedFactsProbeTest#testAnImplicitConstructorCallsSuperAndAnInitializerIsANode :: control :: '
			+ 'M-FACTS-SUPER,M-FACTS-INITIALIZER',
		'unit.check.TypedFactsProbeTest#testAnImportAliasIsATypedefAndTheStaticsOfAnEnumReadAsAType :: control :: '
			+ 'M-FACTS-ALIAS-TYPEDEF,M-FACTS-STATICS-TYPEDEF',
		'unit.check.TypedFactsProbeTest#testAnInlineCallIsNoCallSiteAndItsBodyKeepsTheCalleesPositions :: control :: '
			+ 'M-FACTS-INLINE-POSITIONS,M-FACTS-SAME-FILE-INLINE',
		'unit.check.TypedFactsProbeTest#testAnInlinedCallCarriesWhereItRanAndTheBodyItSplicedIn :: control :: '
			+ 'M-FACTS-SPLICE-SITE,M-FACTS-SPLICE-SITE-INNERMOST,M-FACTS-SPLICE-BODY,M-FACTS-NESTED-SPLICE',
		'unit.check.TypedFactsProbeTest#testCodeNoConfigurationCompiledIsAbsent :: control :: M-FACTS-ABSENT',
		'unit.check.TypedFactsProbeTest#testEveryCallAndFieldAccessKind :: control :: M-FACTS-LOCAL-CALL,M-FACTS-FIELD-WRITE',
		'unit.check.TypedFactsProbeTest#testEveryOverloadIsANodeAndACallNamesTheOneItChose :: control :: M-FACTS-OVERLOADS',
		'unit.check.TypedFactsProbeTest#testEveryValueChannelIntoAnotherTypeIsAFlow :: control :: '
			+ 'M-FACTS-BRANCH-LEAVES,M-FACTS-MONO-SINK,M-FACTS-CAST-ALWAYS,M-FACTS-THROW,M-FACTS-UNTYPED-ARGS,M-FACTS-REST',
		'unit.check.TypedFactsProbeTest#testFactsOfAnotherTextAreAbsent :: control :: '
			+ 'M-FACTS-STALE-SOURCE,M-FACTS-INVALIDATE,M-FACTS-VARIANT-RANGES',
		'unit.check.TypedFactsProbeTest#testFlowsIntoOtherTypes :: control :: M-FACTS-FLOW-CAST,M-FACTS-TYPE-PARAMETER',
		'unit.check.TypedFactsProbeTest#testGenericInstancesInitAndCallsThatNameNoFixedBody :: control :: '
			+ 'M-FACTS-GENERIC,M-FACTS-INIT,M-FACTS-REASSIGNED-LOCAL,M-FACTS-FIELD-VALUE,M-FACTS-REFLECTION-INLINED,M-FACTS-REFLECT-VALUE,'
			+ 'M-FACTS-UNTYPED-DECLARED,M-FACTS-IDENT-READ,M-FACTS-GENERIC-RANGES,M-FACTS-BUILDS',
		'unit.check.TypedFactsProbeTest#testHierarchyIsPackageQualifiedOverTheWholeTypedSet :: control :: M-FACTS-HIERARCHY',
		'unit.check.TypedFactsProbeTest#testLoopsAndStringConversions :: control :: M-FACTS-ITER,M-FACTS-STRING-OPERAND,M-FACTS-TYPE-TEXT',
		'unit.check.TypedFactsProbeTest#testPositionsAreSpanUnitsPastNonAsciiText :: control :: M-CODEPOINT-NATIVE,M-FACTS-READS,M-FACTS-READ-EMIT-NAME',
		'unit.check.TypedFactsProbeTest#testReflectionAndNativeSites :: control :: M-FACTS-REFLECT-NAME,M-FACTS-NATIVE',
		'unit.check.TypedFactsProbeTest#testSplicedCodeIsTheCallersAndItsSiteIsUnknown :: control :: M-FACTS-INLINED-CALL,'
			+ 'M-FACTS-INLINED-CHILD,M-FACTS-GENERATED,M-FACTS-SITE-UNKNOWN,M-FACTS-MACRO-EXPANSION,M-FACTS-SPLICE-OWN-ARGUMENTS',
		'unit.check.TypedFactsProbeTest#testTheTableIsTheUnionOfTheConfigurations :: control :: M-FACTS-UNION',
		'unit.check.TypedFactsProbeTest#testWhatExternCodeIsHandedAndWhatAGenericMethodIsInstantiatedAt :: control :: '
			+ 'M-FACTS-HANDS,M-FACTS-GENS',
		'unit.check.UnguardedNullableDerefTest#testDeclaredNullableFromANullableFieldStillFlagged :: control :: '
			+ 'M-DECL-INIT-RECEIVER-MODE-NOMINAL',
		'unit.check.UnguardedNullableDerefTest#testDeclaredNullableLocalFlagged :: control :: M-DECL-NULLABLE-BLIND',
		'unit.check.UnguardedNullableDerefTest#testDeclaredNullableTernaryWithANullableArmStillFlagged :: control :: '
			+ 'M-DECL-INIT-TERNARY-ANY-ARM',
		'unit.check.UnguardedNullableDerefTest#testDeclaredNullableUnderExistsGuardNotFlagged :: control :: '
			+ 'M-DECL-NULLABLE-OVERRIDES-EXISTS',
		'unit.check.UnguardedNullableDerefTest#testDeclaredNullableWithProvablyNonNullInitializerNotFlagged :: control :: '
			+ 'M-DECL-INIT-NONNULL-BLIND,M-DECL-INIT-LITERAL-BLIND',
		'unit.check.UnguardedNullableDerefTest#testExistsGuardEarlyReturnPathKeySuppressed :: control :: M-EXISTS-GUARD-BLIND',
		'unit.check.UnguardedNullableDerefTest#testFieldPathMapSeedFlagged :: control :: M-NULLABLE-NO-CHAIN',
		'unit.check.UnguardedNullableDerefTest#testInlinePredicateGuardNotFlagged :: control :: M-NULLFLOW-PREDICATE-BLIND',
		'unit.check.UnguardedNullableDerefTest#testPredicateAcrossAConversionStillFlagged :: control :: '
			+ 'M-NULLFLOW-PREDICATE-TYPE-UNCHECKED',
		'unit.check.UnguardedNullableDerefTest#testReflectCopyBindingNotFlagged :: control :: M-NULLABLE-FLOW-EXCLUDE-NONE',
		'unit.check.UnguardedNullableDerefTest#testSafeNavGuardNarrowsRoot :: control :: M-SAFENAV-NO-NARROW',
		'unit.check.UnguardedNullableDerefTest#testUnprovenPredicateStillFlagged :: control :: M-NULLFLOW-PREDICATE-UNCHECKED',
		'unit.check.UnnecessaryNullCheckCheckTest#testTypedefOfNullOperandNotFlagged :: control :: M-PROVER-NULLITY-SKIPPED',
		'unit.check.UnnecessarySafeNavCheckTest#testTypedefOfNullReceiverNotFlagged :: control :: M-PROVER-NULLITY-SKIPPED',
		'unit.check.UnreachableCatchTest#testALaterTypeNamedLikeAProjectSubtypeIsNotCovered :: control :: M-SUBTYPE-START-SIMPLE-NAME',
		'unit.check.UnreachableCatchTest#testNamesakeSupertypeDoesNotCoverTheLaterClause :: control :: M-SUBTYPE-TARGET-SIMPLE-NAME',
		'unit.check.UnreachableCatchTest#testSubtypeAfterSupertypeFlagged :: control :: M-ISSUBTYPE-FALSE',
		'unit.check.UnusedCaseBinderCheckTest#testBinderAnAmbientImportMayBindRefused :: control :: M-SCOPE-AMBIENT-BLIND',
		'unit.check.UnusedCaseBinderCheckTest#testBinderAnImportedModuleFieldMayBindRefused :: control :: M-SCOPE-MODULE-IMPORT-BLIND',
		'unit.check.UnusedCaseBinderCheckTest#testBinderTheLookupOrderMayBindRefused :: control :: '
			+ 'M-SCOPE-IMPORT-BLIND,M-SCOPE-MODULE-FIELDS',
		'unit.check.UnusedCaseBinderCheckTest#testElementBinderNeedsADynamicSubject :: control :: M-CAPTURE-STRUCTURAL',
		'unit.check.UnusedCaseBinderCheckTest#testUndeclaredConstructorArgumentRefused :: control :: '
			+ 'M-UNUSED-BINDER-UNPROVEN,M-CAPTURE-SLOT-UNPROVEN',
		'unit.check.UnusedCaseBinderCheckTest#testWholeBinderNeedsAProvenSubjectType :: control :: M-CAPTURE-SUBJECT-UNPROVEN',
		'unit.check.UnusedLoopBinderCheckTest#testBracedInterpolationRefuses :: control :: M-ULB-INTERP-LITERAL-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testCaseWildcardInBodyStillRenamed :: control :: M-ULB-PATTERN-WILDCARD-UNEXEMPT',
		'unit.check.UnusedLoopBinderCheckTest#testClosureMentionCountsAsRead :: control :: M-ULB-CLOSURE-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testCounterLoopLeftToItsRule :: control :: M-ULB-COUNTER-CLAIM-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testImportAliasedListNotDropped :: control :: M-ULB-IMPORT-ALIAS-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testImportOfAnotherListNotDropped :: control :: M-ULB-IMPORT-REBIND-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testMacroReificationRefuses :: control :: M-ULB-COVERAGE-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testNativeCodeRefuses :: control :: M-ULB-NATIVE-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testObjectLiteralFieldNameIsNoRead :: control :: M-ULB-FIELD-NAME-AS-READ',
		'unit.check.UnusedLoopBinderCheckTest#testOpaqueCondRegionRefuses :: control :: M-ULB-OPAQUE-COND-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testOuterWildcardReadRefuses :: control :: M-ULB-OUTER-WILDCARD-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testProjectListShadowNotDropped :: control :: M-ULB-VALUE-ITERATION-SHADOW-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testReassignedLocalKeyRenamedNotDropped :: control :: M-ULB-REASSIGNED-LOCAL-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testShadowAfterRealReadNotFlagged :: control :: M-ULB-OUTER-BINDING-AS-SHADOW',
		'unit.check.UnusedLoopBinderCheckTest#testShadowInBodyWithoutReadFlagged :: control :: M-ULB-SHADOW-COUNTED-AS-READ',
		'unit.check.UnusedLoopBinderCheckTest#testSimpleInterpolationRefuses :: control :: M-ULB-INTERP-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testUnboundOuterWildcardRefuses :: control :: M-ULB-UNBOUND-WILDCARD-ADMITTED',
		'unit.check.UnusedLoopBinderCheckTest#testUnreadKeyOverALocalMapDroppedOnlyWhereTheLoopLeavesItUnchanged :: control :: '
			+ 'M-ULB-KEYED-UNPROVED-DROPPED',
		'unit.check.UnusedLoopBinderCheckTest#testUnreadKeyOverArrayOrListDropped :: control :: M-ULB-VALUE-ITERATION-NEVER',
		'unit.check.UnusedLoopBinderCheckTest#testUnreadKeyOverMapOrUnknownRenamed :: control :: M-ULB-VALUE-ITERATION-ALWAYS',
		'unit.check.UnusedLoopBinderCheckTest#testUntypedMentionRefuses :: control :: M-ULB-UNTYPED-BLIND',
		'unit.check.UnusedLoopBinderCheckTest#testWildcardBinderNotFlagged :: control :: M-ULB-WILDCARD-KEY-ADMITTED',
		'unit.check.UnusedLoopBinderCheckTest#testWildcardKeyUnreadValueRenamed :: control :: M-ULB-WILDCARD-KEY-VALUE-BLIND',
		'unit.check.UnusedParameterCheckTest#testAccessGrantOutsideReportScopeKeepsParameter :: control :: '
			+ 'M-CONFINEMENT-REPORT-INDEX-PARAM',
		'unit.check.UnusedPrivateCheckTest#testAliasedClassKeepsItsPrivateConstructor :: control :: M-CTOR-ALIAS-BLIND',
		'unit.check.UnusedPrivateCheckTest#testClassPassedAsAValueKeepsItsPrivateConstructor :: control :: M-CTOR-CLASS-VALUE-BLIND',
		'unit.check.UnusedPrivateCheckTest#testClassReachedThroughAQualifiedPathKeepsItsPrivateConstructor :: control :: '
			+ 'M-CTOR-QUALIFIED-BLIND',
		'unit.check.UnusedPrivateCheckTest#testClassReachedThroughAnImportAliasKeepsItsPrivateConstructor :: control :: '
			+ 'M-CTOR-IMPORT-ALIAS-BLIND',
		'unit.check.UnusedPrivateCheckTest#testEntryPointMainIsNeverUnused :: control :: M-ENTRY-POINT-UNREACHED',
		'unit.check.UnusedPrivateCheckTest#testFixDeletesFieldWithPureLiteralOrStdlibInit :: control :: '
			+ 'M-UNUSED-PRIVATE-FIELD-KIND-PURITY',
		'unit.check.UnusedPrivateCheckTest#testMainTakingAParameterIsNoEntryPoint :: control :: M-ENTRY-POINT-ANY-ARITY',
		'unit.check.UnusedPrivateCheckTest#testNamesakeSubtypeNoLongerShieldsAPrivateConstructor :: control :: M-SUBTYPE-KEY-SIMPLE-NAME',
		'unit.check.UnusedPrivateCheckTest#testReflectionCallOutsideReportScopeKeepsMember :: control :: M-REFLECTION-REPORT-INDEX-DELETE',
		'unit.check.UnusedPrivateCheckTest#testStaticReceiverIsNoClassValue :: control :: M-CTOR-RECEIVER-AS-VALUE',
		'unit.check.UnusedPrivateDeclineReasonTest#testEachGateNamesItself :: control :: '
			+ 'M-UNUSED-PRIVATE-DECLINE-SILENT,M-UNUSED-PRIVATE-REGION-DECLINE-SILENT',
		'unit.check.UnusedPrivateSupertypeChainTest#testFixDeletesADeadFinalOfAPureStringMethod :: control :: M-PURE-STRING-METHOD-OFF',
		'unit.check.UnusedPrivateSupertypeChainTest#testFixDeletesTheMethodWhenTheChainProvesNothingDeclaresIt :: control :: '
			+ 'M-UNUSED-PRIVATE-CHAIN-NOT-RESOLVED',
		'unit.check.UnusedPrivateSupertypeChainTest#testFixKeepsTheMethodTheChainMayReach :: control :: '
			+ 'M-UNUSED-PRIVATE-CHAIN-BUILD-IGNORED',
		'unit.check.UnusedPublicMemberCheckTest#testAutoBuildAncestorNotFlagged :: control :: M-REACH-AUTOBUILD-IGNORED',
		'unit.check.UnusedPublicMemberCheckTest#testInterpolationEscapeKeepsTheMember :: control :: M-NAMEOUTSIDE-TRUE',
		'unit.check.UsingDeclineAttributionTest#testCounterLoopConflictNamesTheSkippedSiteAndKeepsTheOther :: control :: '
			+ 'M-COUNT-CONFLICT-SILENT',
		'unit.check.UsingDeclineAttributionTest#testCounterLoopGuardRefusalNamesOnlyTheSurvivingFinding :: control :: '
			+ 'M-COUNT-GUARDED-MIS-ATTRIBUTED',
		'unit.check.UsingDeclineAttributionTest#testEmptyOffsetsRefuseInsteadOfAnsweringInScope :: control :: '
			+ 'M-USING-SCOPE-EMPTY-OFFSETS-INSCOPE',
		'unit.check.UsingDeclineAttributionTest#testEmptyOffsetsStillAnswerAbsentForAnUndeclaredModule :: guard :: ',
		'unit.check.UsingDeclineAttributionTest#testExistsConflictingUsingRefusalNamesItself :: control :: M-BOOL-LOOP-CONFLICT-SILENT',
		'unit.check.UsingDeclineAttributionTest#testFindConflictingUsingRefusalNamesItself :: control :: '
			+ 'M-FIND-CONFLICT-SILENT,M-FIND-CONFLICT-MIS-ATTRIBUTED',
		'unit.check.UsingDeclineAttributionTest#testGuardRefusalNamesOnlyTheFindingItTookDown :: control :: '
			+ 'M-GUARDED-DECLINE-MIS-ATTRIBUTED',
		'unit.check.UsingDeclineAttributionTest#testLpadConflictingUsingRefusalNamesItself :: control :: M-LPAD-CONFLICT-SILENT',
		'unit.check.UsingDeclineAttributionTest#testOffsetInsideTheGuardedRegionIsInScope :: guard :: ',
		'unit.check.UsingDeclineAttributionTest#testOffsetOutsideTheGuardedRegionRefuses :: guard :: ',
		'unit.check.UsingInsertRefusalTest#testBoolLoopCoveredAnchorDropsTheWholeSet :: control :: M-BOOL-LOOP-USING-COVERED-KEPT',
		'unit.check.UsingInsertRefusalTest#testBoolLoopUncoveredAnchorGroupsTheInsert :: guard :: ',
		'unit.check.UsingInsertRefusalTest#testCoveredAnchorRefusesAndAppendsNothing :: control :: M-USING-INSERT-COVERED-SILENT',
		'unit.check.UsingInsertRefusalTest#testStaticExtensionCoveredAnchorRefuses :: control :: M-PSE-USING-INSERT-SILENT',
		'unit.check.UsingInsertRefusalTest#testStaticExtensionUncoveredAnchorAppendsOneEdit :: guard :: ',
		'unit.check.UsingInsertRefusalTest#testUncoveredAnchorStillInserts :: guard :: ',
		'unit.check.UsingMemberFirstParityTest#testAForwardAbstractReceiverKeepsTheUsing :: guard :: ',
		'unit.check.UsingMemberFirstParityTest#testAGuardedMemberKeepsTheUsing :: control :: M-MEMBER-BINDS-GUARDED',
		'unit.check.UsingMemberFirstParityTest#testAProjectTypeSharingTheStdNameKeepsTheUsing :: control :: M-MEMBER-DOOR-SHADOW',
		'unit.check.UsingMemberFirstParityTest#testAStaticOfTheNameKeepsTheUsing :: control :: M-MEMBER-BINDS-STATIC',
		'unit.check.UsingMemberFirstParityTest#testAStdMemberCallNeedsNoUsing :: control :: M-USING-MEMBER-FIRST-OFF',
		'unit.check.UsingMemberFirstParityTest#testATypeDeclaredPerBranchKeepsTheUsing :: control :: M-MEMBER-BINDS-HOST-GUARDED',
		'unit.check.UsingMemberFirstParityTest#testAnInheritedMemberCallNeedsNoUsing :: control :: M-USING-MEMBER-FIRST-OFF',
		'unit.check.UsingMemberFirstParityTest#testAnOwnMemberCallNeedsNoUsing :: control :: '
			+ 'M-USING-MEMBER-FIRST-OFF,M-UNUSED-USING-NO-DOOR,M-CARRY-USING-DOOR-OFFSET',
		'unit.check.UsingMemberFirstParityTest#testTheStdListingProvesOnlyAnUnguardedInstanceMember :: control :: '
			+ 'M-STD-MEMBER-STATIC,M-STD-MEMBER-VIA-GUARD,M-STD-MEMBER-ANY-CANDIDATE',
		'unit.check.UsingSitesTest#testAFieldSpelledLikeATypeIsNoTypeExpression :: control :: M-USING-STATIC-SHADOW',
		'unit.check.UsingSitesTest#testAForwardAbstractReceiverKeepsTheModule :: control :: M-USING-FORWARD-DECIDED',
		'unit.check.UsingSitesTest#testAModuleARivalOutranksIsUnused :: control :: M-USING-BOUND-ELSEWHERE',
		'unit.check.UsingSitesTest#testAModuleWhoseCandidatesRejectTheReceiverIsUnused :: control :: M-USING-OFFER-OPEN',
		'unit.check.UsingSitesTest#testARivalContestsOnlyAnAccessBothMayOffer :: control :: M-USING-OFFER-OPEN,M-USING-CONTEST-ANY',
		'unit.check.UsingSitesTest#testAStaticOfATypeExpressionIsNoUse :: control :: M-USING-STATIC-RECEIVER',
		'unit.check.UsingSitesTest#testATypeArgumentOnTheFirstParameterKeepsEveryModule :: guard :: ',
		'unit.check.UsingSitesTest#testAValueSpelledLikeATypeIsNoTypeExpression :: control :: M-USING-STATIC-SHADOW',
		'unit.check.UsingSitesTest#testAnAccessTheModuleBindsOrCannotBeTypedKeepsIt :: guard :: '
	];

}
