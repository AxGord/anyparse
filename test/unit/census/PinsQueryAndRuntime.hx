package unit.census;

/**
 * Part of the pin census `unit.PinCensusParityTest` compares with `TestRegistry.pins()`:
 * the pins from `'unit.query.'` to the end: `unit.query` and `unit.runtime`
 *
 * SORTED, in code-unit order (`TestRegistry.pins()` sorts so): a new pin goes into the part
 * whose range holds it, at its sorted place — `hxq add-element test/unit/census/PinsQueryAndRuntime.hx --sorted
 * --select 'FinalMember:PINS >> ArrayExpr' "'<entry>'" --write`. The parts concatenate in
 * range order, so an entry in the wrong part fails the census as a misordered list.
 */
@:nullSafety(Strict)
final class PinsQueryAndRuntime {

	public static final PINS: Array<String> = [
		'unit.query.AbstractCastsTest#testACoreClauseWidens :: control :: M-UNIFY-CORE-WIDENS',
		'unit.query.AbstractCastsTest#testAHeaderClauseChainsOnlyThroughATransitiveAbstract :: control :: M-UNIFY-CAST-TRANSITIVE',
		'unit.query.AbstractCastsTest#testAMemberNotInEveryBuildIsNotDecided :: control :: M-CASTS-MEMBER-CERTAIN,M-CASTS-BUILD-OPEN',
		'unit.query.AbstractCastsTest#testAnArgumentCastsThroughAConversionMember :: control :: M-CASTS-MEMBERS-OFF',
		'unit.query.AbstractCastsTest#testTheFirstUnequalFromAloneIsCastTo :: control :: M-CASTS-FIRST-FROM,M-CASTS-FIRST-ONLY,M-CASTS-CORE-ABSTRACT',
		'unit.query.AddElementSliceTest#testInsertBeforeAFinalClassAddressedThroughItsForm :: control :: M-LIFT-FINAL-WRAPPER-SKIPPED',
		'unit.query.AddElementSortedTest#testConcatenatedEntriesSortByTheirValue :: control :: M-SORTED-NO-CONCAT',
		'unit.query.AddElementSortedTest#testDuplicateIsRefused :: control :: M-SORTED-DUP-UNCHECKED',
		'unit.query.AddElementSortedTest#testEmptyArray :: control :: M-SORTED-UNSORTED-ENTRIES',
		'unit.query.AddElementSortedTest#testEntryLandsAboveTheNextElementsDoc :: control :: M-SORTED-SPLITS-DOC',
		'unit.query.AddElementSortedTest#testEscapedOrInterpolatedEntryIsRefused :: control :: M-SORTED-RAW-ESCAPES',
		'unit.query.AddElementSortedTest#testNonArrayContainerIsRefused :: control :: M-SORTED-ANY-CONTAINER',
		'unit.query.AddElementSortedTest#testUnsortedListIsRefused :: control :: M-SORTED-ORDER-UNCHECKED',
		'unit.query.AddImportSliceTest#testCliSeatReadsTheWildcardAsRunMember :: control :: M-ADDIMPORT-CLI-BLIND-SEAT',
		'unit.query.AddImportSliceTest#testCliTakesAWholeUsingStatement :: control :: M-ADDIMPORT-STATEMENT-KEYWORD-IGNORED',
		'unit.query.AddImportSliceTest#testImportStatementUnderTheUsingFlagIsRefused :: control :: M-IMPORTSPELLING-FLAG-CONFLICT-UNCHECKED',
		'unit.query.AddImportSliceTest#testNotAModulePathIsRefusedByName :: control :: M-ADDIMPORT-PATH-UNCHECKED',
		'unit.query.AddImportSliceTest#testUsingOnlyHeaderTakesTheLowestPriority :: control :: M-ADDIMPORT-USING-TAKES-IMPORT-SEAT',
		'unit.query.AddImportSliceTest#testWholeUsingStatementAddsAUsing :: control :: M-ADDIMPORT-STATEMENT-KEYWORD-IGNORED',
		'unit.query.AddMetaSliceTest#testCliWritesTheEntry :: control :: M-ADDMETA-CLI-UNROUTED',
		'unit.query.AddMetaSliceTest#testFinalClassWrapperIsLifted :: control :: M-ADDMETA-NO-WRAPPER-CLIMB',
		'unit.query.AddMetaSliceTest#testGuardedTypeKeepsTheEntryInsideTheGuard :: control :: M-ADDMETA-LOOSE-WRAPPER-CLIMB',
		'unit.query.AddMetaSliceTest#testSameNameWithDifferentArgsAdded :: control :: M-ADDMETA-SAME-ARGS',
		'unit.query.AddMetaSliceTest#testSameNameWithSameArgsRefused :: control :: M-ADDMETA-ENTRY-NEVER-SAME',
		'unit.query.AddMetaSliceTest#testTypeEntryLandsBelowTheDoc :: control :: M-ADDMETA-ZERO-WIDTH-INSERT',
		'unit.query.AddParamSliceTest#testASignatureThatNoLongerFitsComesBackCanonical :: control :: M-SIGNATURE-EDIT-RAW-SPLICE',
		'unit.query.AddressTest#testAModuleLevelNodeIsAddressedFromTheRootNotByOrdinal :: control :: M-ADDRESS-NO-ROOT-ANCHOR',
		'unit.query.AddressTest#testAnAmbiguityListingSpellsTheSelectorThatPicksOneCandidate :: control :: '
			+ 'M-CANDIDATE-LABEL-BARE,M-ADDRESS-NO-ROOT-ANCHOR',
		'unit.query.AddressTest#testMintedKindIsAdmittedAndSuggestible :: control :: M-KIND-CLAUSE-POOL-GRAMMAR-ONLY',
		'unit.query.AddressTest#testSelectUnknownKindIsNamedAsUnknown :: control :: M-SELECT-MISS-NO-KIND-CLAUSE',
		'unit.query.AmbientImportResolutionTest#testAChainThatCannotBeBoundedIsReportedUnbounded :: control :: M-AMBIENT-CHAIN-ROOT',
		'unit.query.AmbientImportResolutionTest#testAFilesOwnImportOutranksTheAmbientOne :: guard :: ',
		'unit.query.AmbientImportResolutionTest#testAGuardedAmbientImportAnswersBothBuildsInsteadOfPinningOne :: control :: '
			+ 'M-AMBIENT-GUARDED-UNION',
		'unit.query.AmbientImportResolutionTest#testAGuardedOwnImportAnswersBothBuildsInsteadOfPinningOne :: control :: '
			+ 'M-AMBIENT-GUARDED-UNION',
		'unit.query.AmbientImportResolutionTest#testAModuleAbsentFromDiskHasNoChainAtAll :: control :: M-AMBIENT-DISK-BLIND',
		'unit.query.AmbientImportResolutionTest#testAmbientSourceOutranksTheSamePackageNamesake :: control :: M-AMBIENT-IMPORT-BAND',
		'unit.query.AmbientImportResolutionTest#testAmbientUsingAndWildcardBindTheirTypesBySimpleName :: control :: M-AMBIENT-CHAIN-EMPTY',
		'unit.query.AmbientImportResolutionTest#testAnAmbientSourceThatCannotBeReadLeavesTheChainUnbounded :: control :: '
			+ 'M-AMBIENT-UNREADABLE-BOUNDED',
		'unit.query.AmbientImportResolutionTest#testAnAmbientSourceThatDoesNotParseLeavesTheChainUnbounded :: control :: '
			+ 'M-AMBIENT-UNPARSED-EMPTY',
		'unit.query.AmbientImportResolutionTest#testAnExplicitImportOutranksEveryWildcardOne :: control :: M-AMBIENT-IMPORT-BAND',
		'unit.query.AmbientImportResolutionTest#testAnOwnRootPackageImportOutranksTheAmbientNamesake :: control :: M-AMBIENT-IMPORT-BAND',
		'unit.query.AmbientImportResolutionTest#testTheChainIsOrderedNearestFirst :: control :: M-AMBIENT-CHAIN-ROOT',
		'unit.query.AmbientImportResolutionTest#testTheChainReachesTheSourceRootAndStopsThere :: control :: M-AMBIENT-CHAIN-ROOT',
		'unit.query.AmbientImportResolutionTest#testTheEngineResolvesThroughAChainItDidNotComputeItself :: control :: '
			+ 'M-AMBIENT-IMPORT-BAND',
		'unit.query.AmbientImportResolutionTest#testTheImportMapCarriesAmbientBindingsOnlyWhenGivenAPath :: control :: '
			+ 'M-AMBIENT-IMPORT-MAP',
		'unit.query.AmbientImportResolutionTest#testTheNearestAmbientSourceWinsAndTheParentStillBinds :: control :: M-AMBIENT-IMPORT-BAND',
		'unit.query.ApqMatcherTest#testTryPatternMatchesEveryPosition :: control :: M-SEARCH-TRY-EXPR-UNRELATED',
		'unit.query.ApqMatcherTest#testTypeArgumentsAndValueArgumentsAreSeparateRuns :: control :: '
			+ 'M-MATCH-ONE-FLAT-RUN,M-WALK-TYPE-ARGS-UNCOUNTED',
		'unit.query.ApqUsesTest#testQualifiedIsOptInSoRewritersKeepTheExactAnswer :: control :: M-USES-QUALIFIED-DEFAULT',
		'unit.query.ApqUsesTest#testQualifiedSpellingsAcrossTypePositions :: control :: M-USES-EXACT-ONLY',
		'unit.query.ApqUsesTest#testQualifiedSubModuleTypeIsFoundBySimpleName :: control :: M-USES-EXACT-ONLY',
		'unit.query.ApqUsesTest#testQualifiedTailMatchesOnlyOnASegmentBoundary :: control :: M-USES-TAIL-SUBSTRING',
		'unit.query.ApqUsesTest#testStructExtensionIsATypeRef :: control :: M-XREN-EXTENDS-KIND-DROPPED',
		'unit.query.ArgumentSlotsTest#testABindingNeverBacktracks :: control :: M-SLOTS-FIT-SKIPS',
		'unit.query.ArgumentSlotsTest#testAFitBindsWhereItMeets :: control :: M-SLOTS-FIT-SKIPS',
		'unit.query.ArgumentSlotsTest#testAMandatoryParameterIsNeverSkipped :: control :: M-SLOTS-MANDATORY-MISFIT',
		'unit.query.ArgumentSlotsTest#testAMisfitSkipsAnOptionalParameter :: control :: M-SLOTS-MISFIT-BINDS',
		'unit.query.ArgumentSlotsTest#testARestParameterTakesEveryArgumentLeft :: control :: M-SLOTS-REST-ONCE',
		'unit.query.ArgumentSlotsTest#testAnUndecidedFitIsFollowedBothWays :: control :: M-SLOTS-MAYFIT-BINDS-ONLY',
		'unit.query.ArgumentSlotsTest#testTooManyArgumentsOrTooFewAreNoRun :: control :: M-SLOTS-UNBOUND-MANDATORY',
		'unit.query.ArgumentSlotsTest#testTooManyWaysAnswerNone :: control :: M-SLOTS-OVERFLOW-PARTIAL',
		'unit.query.BodySlotGuardSliceTest#testAllowsAuthoredBodyThatTakesInTheNextStatement :: control :: M-BODYSLOT-AUTHORED-NEVER',
		'unit.query.BodySlotGuardSliceTest#testAllowsHeaderRewriteOfBracelessConstruct :: control :: M-BODYSLOT-LIMIT-EDIT-END',
		'unit.query.BodySlotGuardSliceTest#testAllowsSoleCatchClauseRemoval :: control :: M-BODYSLOT-LEAD-KEPT',
		'unit.query.BodySlotGuardSliceTest#testAllowsSoleCatchClauseRemovalWithATrailingComment :: control :: M-BODYSLOT-TRIM-WS-ONLY',
		'unit.query.BodySlotGuardSliceTest#testAllowsWholeElseBranchRemoval :: control :: M-BODYSLOT-LEAD-KEPT',
		'unit.query.CachingGrammarPluginTest#testRetainSourcesDropsOnlyTheSupersededTexts :: control :: '
			+ 'M-RETAIN-SOURCES-KEEPS-ALL,M-RETAIN-SOURCES-DROPS-LIVE',
		'unit.query.CallGraphBindingTest#testAClassExtendingAnAliasIsASubtypeOfItsTarget :: control :: M-TS-REACH-ALIAS-SUBTYPES',
		'unit.query.CallGraphBindingTest#testAContainerIsTheStdOneOnlyWhereItsWritingFileBindsIt :: control :: '
			+ 'M-TS-STD-CONTAINER-DECLARED,M-TS-STD-CONTAINER-WHERE,M-TS-NULLABLE-PATH-KEY',
		'unit.query.CallGraphBindingTest#testAModuleLevelFunctionSeesItsModuleAndImportsNoClassChain :: control :: '
			+ 'M-TS-MODULE-FN-CLASS-CHAIN,M-TS-MODULE-FN-IMPORTED-REF',
		'unit.query.CallGraphBindingTest#testASupertypeIsTheTypeItsDeclaringFileBinds :: control :: M-SUPERS-BY-DECLARATION',
		'unit.query.CallGraphBindingTest#testATypeParametersBoundIsNoReturnType :: control :: M-GRAPH-RETURN-BOUND',
		'unit.query.CallGraphBindingTest#testDispatchTargetsArePerMemberAndFollowTheGraph :: control :: M-CG-DISPATCH-MEMO-LEAKS,M-CG-DISPATCH-MEMO-BY-TYPE',
		'unit.query.CallGraphBindingTest#testEachBodyOfAModuleLevelFunctionUnderIfIsANodeOfItsOwn :: control :: '
			+ 'M-GRAPH-BODY-SPLIT,M-GRAPH-BODY-EXPAND,M-GRAPH-BODY-EXACT,M-GRAPH-BODY-TARGETS,M-GRAPH-BODY-COPY-IN,M-GRAPH-BODY-PURGE,'
			+ 'M-GRAPH-MODULE-BINDING,M-GRAPH-MODULE-BINDING-MEMBER,M-GRAPH-MODULE-BINDING-VALUE,'
			+ 'M-GRAPH-MODULE-BINDING-IMPORTS,M-GRAPH-MODULE-REF,M-GRAPH-MODULE-IDENT',
		'unit.query.CallGraphTest#testACallReceiverBoundToANullableTypeDispatchesOnIt :: control :: M-TS-RETURN-WRAPPER-BOUND',
		'unit.query.CallGraphTest#testACalledFunctionValueReturnsWhatItsFunctionTypeSays :: control :: '
			+ 'M-TS-CALLED-VALUE,M-TS-CALLED-RECEIVER,M-TS-CALLED-NULL',
		'unit.query.CallGraphTest#testAContainerIsTheStandardOneOnlyWhereItsNameMeansIt :: control :: '
			+ 'M-TS-STD-CONTAINER,M-TS-STD-CONTAINER-WHERE,M-TS-STD-CONTAINER-GUARDED,M-TS-STD-CONTAINER-STD-OWN',
		'unit.query.CallGraphTest#testADeclaredTypeIsReadInTheFileThatWroteIt :: control :: '
			+ 'M-TS-DECL-MEMBER-FILE,M-TS-DECL-RETURN-FILE,M-TS-DECL-READ-FROM,M-TS-DECL-BOUND,M-TS-PATH-NULLABLE-KEYED',
		'unit.query.CallGraphTest#testAForwardedCallRunsTheUnderlyingTheAbstractsFileNames :: control :: '
			+ 'M-TS-FORWARD-KEYED,M-TS-FORWARD-PARAM,M-TS-FORWARD-ALIAS',
		'unit.query.CallGraphTest#testAFunctionOfferingOtherSignaturesIsTypedWhereTheyAgree :: control :: M-TS-OVERLOAD-RETURN,'
			+ 'M-TS-OVERLOAD-RETURN-EACH,M-TS-OVERLOAD-PARAMS,M-TS-OVERLOAD-AGREE,M-TS-OVERLOAD-EXTERNAL,M-TS-OVERLOAD-OWN-PARAMS',
		'unit.query.CallGraphTest#testAFunctionsOwnTypeParameterIsWhatItsArgumentsBind :: control :: '
			+ 'M-GRAPH-FN-RETURN-PARAM,M-TS-INFER-AGREE,M-TS-INFER-REST,M-TS-INFER-SHADOW,M-TS-INFER-BARE,M-TS-INFER-SHIFT',
		'unit.query.CallGraphTest#testALambdaParameterIsNoReferenceToItsLambda :: control :: M-GRAPH-LAMBDA-PARAM-SELF',
		'unit.query.CallGraphTest#testALambdaParameterIsTypedByTheFunctionTypeItIsExpectedToBe :: control :: '
			+ 'M-TS-LAMBDA-PARAMS,M-TS-LAMBDA-ARITY,M-TS-LAMBDA-ANNOTATED,M-TS-LAMBDA-NULL',
		'unit.query.CallGraphTest#testALoopBindsWhatItsIterableYields :: control :: M-TS-LOOP-ELEMENT,M-TS-LOOP-KEY-BINDER,'
			+ 'M-TS-LOOP-KV-LISTED,M-TS-LOOP-ITERATOR,M-TS-LOOP-NEXT,M-TS-LOOP-AGREE,M-TS-LOOP-OWN-PARAMS,M-TS-LOOP-THROUGH',
		'unit.query.CallGraphTest#testAModuleLevelFieldComesBeforeAnImportedStatic :: control :: '
			+ 'M-TS-MODULE-NAME-NESTED,M-TS-MODULE-NAME-ALIAS',
		'unit.query.CallGraphTest#testAModuleLevelValueUnderIfBindsInTheBuildsThatCompileIt :: control :: M-GRAPH-MODULE-VALUE-TYPED,'
			+ 'M-GRAPH-MODULE-VALUE-MEMBER-FIRST,M-GRAPH-MODULE-RECEIVERS,M-GRAPH-MODULE-RECEIVERS-IMPORTS,M-GRAPH-MODULE-RECEIVERS-MEMBER,'
			+ 'M-GRAPH-MODULE-RECEIVERS-UNTYPED,M-GRAPH-IMPORTED-POSITION,M-TS-MODULE-NAME,M-GRAPH-MODULE-CALL-UNSEEN',
		'unit.query.CallGraphTest#testANameNoImportBindsIsLookedUpInTheFilesPackages :: control :: '
			+ 'M-TS-PACKAGE-LOOKUP,M-TS-PACKAGE-ENCLOSING,M-TS-PACKAGE-PROJECT-FIRST',
		'unit.query.CallGraphTest#testAReceiverANewMakesIsOfTheTypeItNames :: control :: M-TS-NEW-RECEIVER',
		'unit.query.CallGraphTest#testASupertypeStaticIsNotInScopeBare :: control :: M-TS-SUPER-STATIC-IMPORT,M-TS-SUPER-STATIC-READ,'
			+ 'M-TS-SUPER-STATIC-CALL,M-TS-SUPER-STATIC-HIDDEN,M-TS-SUPER-STATIC-MODULE,M-TS-SUPER-STATIC-MODULE-IMPORT',
		'unit.query.CallGraphTest#testATypeAnAliasASupertypeOrAnAbstractWritesIsReadWhereItIsWritten :: control :: '
			+ 'M-TS-DECL-SUPER-ARGS,M-TS-DECL-PARAM-FILE,M-TS-DECL-UNDERLYING',
		'unit.query.CallGraphTest#testATypeParameterIsNeverKeyedThroughAnImport :: control :: '
			+ 'M-TS-KEY-TYPE-PARAM,M-TS-KEY-MEMBER-PARAMS,M-TS-KEY-SCOPE-PARAMS,M-TS-KEY-RETURN-PARAMS',
		'unit.query.CallGraphTest#testATypedefAliasesWhatItsOwnFileBindsTheTargetTo :: control :: M-TS-ALIAS-KEYED,M-TS-ALIAS-AGREE',
		'unit.query.CallGraphTest#testAWildcardOrGuardedNameDispatchesToEveryTypeItMayBe :: control :: '
			+ 'M-TS-WILD-EXPLICIT-NO-MAYBE,M-TS-WILD-MAYBE,M-TS-WILD-GUARDED,M-TS-WILD-PROJECT,M-TS-WILD-ORDER,M-TS-STD-PACKAGES,'
			+ 'M-TS-ALTERNATE-SAME,M-TS-ALTERNATE-NEW',
		'unit.query.CallGraphTest#testAddFilesUpgradesTheExternalPlaceholder :: control :: M-GRAPH-UPGRADE-EXTERNAL',
		'unit.query.CallGraphTest#testAnAlternateTypeResolvesTheCallWhateverTheNamesakeDeclares :: control :: M-TS-ALTERNATE-WHOLE-CALL',
		'unit.query.CallGraphTest#testAnArgumentAfterASkippableParameterBindsNoKnownParameter :: control :: '
			+ 'M-TS-SKIP-SHIFT,M-TS-SKIP-DEFAULT,M-TS-SKIP-NEW-ARGS',
		'unit.query.CallGraphTest#testAnImportedStaticIsTypedWhereItIsDeclared :: control :: '
			+ 'M-TS-IMPORT-STATIC-FIELD,M-TS-IMPORT-STATIC-CALL,M-TS-IMPORT-STATIC-OWN,M-TS-IMPORT-STATIC-ONE,M-TS-IMPORT-STATIC-INDEXED',
		'unit.query.CallGraphTest#testBareCallSomethingElseMaySupplyIsNeverAConstructor :: control :: '
			+ 'M-GRAPH-IMPORT-UNLISTED,M-GRAPH-UNLISTED-WILDCARD',
		'unit.query.CallGraphTest#testBareStaticCallGetsNoVirtualEdge :: control :: M-GRAPH-STATIC-NO-VIRTUAL',
		'unit.query.CallGraphTest#testCallToAMemberOfAnUnloadedSupertypeKeepsItsDispatch :: control :: '
			+ 'M-GRAPH-PLACEHOLDER-DISPATCH,M-GRAPH-PLACEHOLDER-DECLARING',
		'unit.query.CallGraphTest#testConstructionRunsTheInstanceInitializersOnly :: control :: '
			+ 'M-GRAPH-INIT-WIRING,M-GRAPH-CTOR-OWN-INIT,M-GRAPH-STATIC-INIT',
		'unit.query.CallGraphTest#testConstructorArgumentsHandOnEveryFunctionValue :: control :: M-GRAPH-NEW-ARGS',
		'unit.query.CallGraphTest#testConstructorNotLoadedYetIsTheOneTheChainDeclares :: control :: M-GRAPH-CTOR-PLACEHOLDER',
		'unit.query.CallGraphTest#testDeclarationsWritingATypeDifferentlyDispatchOnEach :: control :: '
			+ 'M-TS-DECL-EACH-MEMBER,M-TS-DECL-EACH-RETURN,M-TS-DECL-EACH-UNTYPED,M-TS-KEY-LINED',
		'unit.query.CallGraphTest#testDynamicMethodCallIsAlsoAFunctionValueCall :: control :: M-GRAPH-DYNAMIC-METHOD',

		'unit.query.CallGraphTest#testEnumConstructorSharingAStaticFunctionNameIsUnresolved :: control :: M-GRAPH-ENUM-VS-STATIC',
		'unit.query.CallGraphTest#testEveryUsingThatDeclaresTheExtensionIsATarget :: control :: M-GRAPH-USING-ALL',
		'unit.query.CallGraphTest#testEveryValueUseOfAFunctionIsARef :: control :: M-GRAPH-VALUE-USE,M-GRAPH-VALUE-USE-LAMBDA',
		'unit.query.CallGraphTest#testForwardAbstractRoutesToTheUnderlying :: control :: M-GRAPH-FORWARD,M-GRAPH-FORWARD-ONLY',
		'unit.query.CallGraphTest#testFunctionTypeParameterNamesNoType :: control :: M-GRAPH-FN-TYPE-PARAM',
		'unit.query.CallGraphTest#testGrowingTheGraphAddsNoConstructorEdgeTwice :: control :: M-GRAPH-WIRED-ONCE',
		'unit.query.CallGraphTest#testImportedStaticIsResolved :: control :: M-GRAPH-IMPORTED-STATIC',
		'unit.query.CallGraphTest#testInstanceCallRecordsTheTypeItDispatchesOn :: control :: M-GRAPH-DISPATCH-TYPE',
		'unit.query.CallGraphTest#testInterfacePropertyRunsOnlyItsImplementations :: control :: '
			+ 'M-GRAPH-INTERFACE-PROPERTY,M-GRAPH-BODYLESS-FLAG',
		'unit.query.CallGraphTest#testLiteralTypedAsAConstructedClassIsANew :: control :: '
			+ 'M-GRAPH-CONSTRUCTION-LITERAL,M-GRAPH-LITERAL-ARGUMENT,M-GRAPH-LITERAL-ELEMENT,M-GRAPH-LITERAL-RETURN,M-GRAPH-LITERAL-ARMS,'
			+ 'M-GRAPH-LITERAL-REST,M-GRAPH-LITERAL-LAMBDA,M-GRAPH-LITERAL-MAP,M-GRAPH-LITERAL-FIELD',
		'unit.query.CallGraphTest#testMethodValueOfATypeNotLoadedYetIsKept :: control :: M-GRAPH-UNLOADED-METHOD-VALUE',
		'unit.query.CallGraphTest#testMethodValueReachesTheOverrides :: control :: M-GRAPH-REF-OVERRIDES',
		'unit.query.CallGraphTest#testMethodValueThroughNullSafeAccessIsARef :: control :: M-GRAPH-SAFE-METHOD-VALUE',
		'unit.query.CallGraphTest#testOneFileUnderTwoSpellingsIsOneFile :: control :: M-GRAPH-PATH-SPELLING,M-GRAPH-INHERITED-PLACEHOLDER',
		'unit.query.CallGraphTest#testPropertyAccessRunsItsAccessor :: control :: M-GRAPH-SETTER-EDGE,M-GRAPH-GETTER-EDGE,'
			+ 'M-GRAPH-ELEMENT-RECEIVER,M-GRAPH-OWN-ACCESSOR-ANY-RECEIVER,M-GRAPH-SETTER-READ-DIRECT',
		'unit.query.CallGraphTest#testReceiverFieldNamesAMemberReadOffATypedValue :: control :: M-GRAPH-RECEIVER-TYPED-BASE',
		'unit.query.CallGraphTest#testReceiverFieldNamesOnlyAMemberReadDirectly :: control :: M-GRAPH-RECEIVER-LOCAL-FIELD',
		'unit.query.CallGraphTest#testReceiverFieldSkipsAPropertyWithAGetter :: control :: M-GRAPH-RECEIVER-PROPERTY',
		'unit.query.CallGraphTest#testReceiverTypedThroughDeclaredMemberTypes :: control :: M-GRAPH-FIELD-PATH-RECEIVER',
		'unit.query.CallGraphTest#testResolveTargetBareAndQualified :: control :: M-TS-DOTTED-TARGET',
		'unit.query.CallGraphTest#testStaticExtensionResolvesThroughTheUsing :: control :: M-GRAPH-USING-EXTENSION',
		'unit.query.CallGraphTest#testStaticFieldReadOffItsTypeIsTyped :: control :: M-GRAPH-STATIC-FIELD-TYPE',
		'unit.query.CallGraphTest#testSuperCallRunsTheGeneratedConstructorsInitializers :: control :: M-GRAPH-SUPER-CTOR-RUN',
		'unit.query.CallGraphTest#testSuperIsTheSuperclassWhateverTheHeaderOrder :: control :: M-GRAPH-SUPERCLASS',
		'unit.query.CallGraphTest#testSuperOfAnAmbiguousNameIsUnresolved :: control :: M-GRAPH-SUPER-AMBIGUOUS',
		'unit.query.CallGraphTest#testSupertypesOfASharedNameAreUnioned :: control :: M-GRAPH-SUPERS-UNION',
		'unit.query.CallGraphTest#testThisInsideAnAbstractIsItsUnderlyingNotAParameterBound :: control :: '
			+ 'M-GRAPH-ABSTRACT-UNDER-SLOT,M-GRAPH-ABSTRACT-PARAM-BOUND',
		'unit.query.CallGraphTest#testThisInsideAnAbstractIsTheUnderlyingValue :: control :: M-GRAPH-ABSTRACT-THIS',
		'unit.query.CallGraphTest#testThisInsideAnAbstractOverAnAliasIsTheAliasedType :: control :: M-GRAPH-ABSTRACT-THIS-ALIAS',
		'unit.query.CallGraphTest#testTwoDeclarationsKeyingAMemberApartDispatchOnBoth :: control :: '
			+ 'M-TS-KEY-APART,M-TS-KEY-APART-FIRST,M-TS-DECL-FILES-AGREE',
		'unit.query.CallGraphTest#testTypeParameterBoundsOfSameNamedTypesStayApart :: control :: M-GRAPH-BOUNDS-BY-FILE',
		'unit.query.CallGraphTest#testTypeParameterIsLookedUpWhereTheReceiverTypeWasWritten :: control :: '
			+ 'M-GRAPH-BOUND-DECL-SCOPE,M-GRAPH-BOUND-LOCAL-SCOPE',
		'unit.query.CallGraphTest#testTypeParameterReceiverResolvesThroughItsBound :: control :: '
			+ 'M-GRAPH-CLASS-BOUND,M-GRAPH-FINAL-CLASS-BOUND,M-GRAPH-FN-BOUND,M-GRAPH-BOUND-DECLARING',
		'unit.query.CallGraphTest#testTypeParametersInsideWrittenTypesAreSubstituted :: control :: M-GRAPH-TYPE-ARGUMENT,'
			+ 'M-GRAPH-UNSUBSTITUTED-PARAM,M-GRAPH-RETURN-PARAM,M-GRAPH-FN-RETURN-PARAM,M-GRAPH-INHERITED-ARGS,M-GRAPH-CALL-ELEMENT',
		'unit.query.CallGraphTest#testTypeParametersResolveThroughTheirArguments :: control :: M-GRAPH-TYPE-ARGUMENT,M-GRAPH-TYPE-PARAM',
		'unit.query.CallGraphTest#testTypedefAliasIsSeenThrough :: control :: M-GRAPH-TYPEDEF-ALIAS',
		'unit.query.CallGraphTest#testTypedefReExportIsNotASecondDeclaration :: control :: M-GRAPH-SELF-ALIAS-COUNT',
		'unit.query.CallGraphTest#testUnboundCapitalizedCallIsUnresolvedUnlessAnEnumConstructor :: control :: M-GRAPH-UNBOUND-CAPITAL',
		'unit.query.CallGraphTest#testUnresolvedCallsCarryTheirReasonAndCaller :: control :: '
			+ 'M-GRAPH-DYNAMIC-RECEIVER,M-GRAPH-FIELD-FUNCTION-VALUE',
		'unit.query.CallGraphTest#testUntypedPropertyAccessIsRecordedAgainstItsAccessor :: control :: '
			+ 'M-GRAPH-ACCESS-RECORDED,M-GRAPH-ACCESS-COUNTED',
		'unit.query.CallSelectionTest#testAFunctionsSignaturesAreItsOwnThenEachAnnotations :: control :: '
			+ 'M-INDEX-SIGNATURES-META,M-SIGNATURE-FORM-OPTIONAL,M-SIGNATURE-FORM-DEFAULTED,M-SIGNATURE-RETURN-SOURCE,'
			+ 'M-SPANINFO-RETURN-SOURCES,M-SIGNATURE-RETURN-TRIM',
		'unit.query.CallSelectionTest#testATypeParameterTheArgumentsBindIsTheirType :: control :: '
			+ 'M-CALLS-PARAM-FREE,M-CALLS-PARAM-AGREE,M-CALLS-PARAM-SPELLED,M-SIGNATURE-PARAM-BOUNDS',
		'unit.query.CallSelectionTest#testAnAnnotationWritingNoFunctionLeavesNoSignatures :: control :: M-INDEX-SIGNATURES-BARE',
		'unit.query.CallSelectionTest#testAnAppliedAbstractIsItselfAppliedAlike :: control :: M-CASTS-APPLIED-SAME',
		'unit.query.CallSelectionTest#testTheCandidateACallBinds :: control :: '
			+ 'M-CALLS-CHOSEN-FIRST,M-CALLS-CHOSEN-LAST-OPEN,M-CALLS-CHOSEN-PROPER',
		'unit.query.CallSelectionTest#testTheSelectionOverTypedArguments :: control :: '
			+ 'M-CALLS-FIT-CAST,M-CALLS-PROPER-STATIC,M-CALLS-RETURN-AGREE',
		'unit.query.CallSelectionTest#testWhetherACallCompilesAgainstASignature :: control :: '
			+ 'M-SLOTS-COMPILES-DECIDED,M-SLOTS-COMPILES-NONE,M-SLOTS-COMPILES-UNSAFE-SKIP,M-SLOTS-COMPILES-MAYFIT',
		'unit.query.CallSitesTest#testASecondLocalFunctionOfTheSameNameRefusesTheProof :: control :: M-NAME-CLASH-KINDS-NO-BINDERS',
		'unit.query.CaseCaptureTest#testAlternativesShareTheFirstCapture :: control :: M-CAPTURE-ALT-SELF',
		'unit.query.CaseCaptureTest#testBareCaptureBindsItsArm :: control :: M-CAPTURE-ARM-BIND',
		'unit.query.CaseCaptureTest#testCalleeAndExtractorStayReads :: control :: M-PATTERN-CALLEE-CAPTURE',
		'unit.query.CaseCaptureTest#testConstantNamedPatternIsARead :: control :: M-PATTERN-CONST-DECIDED',
		'unit.query.CaseCaptureTest#testExtractorLeftSideReadsTheOuterBinding :: control :: M-CAPTURE-VISIBLE-FROM-ARM',
		'unit.query.CaseCaptureTest#testInlineLeavesTheCaptureAlone :: control :: M-CAPTURE-ARM-BIND',
		'unit.query.CaseCaptureTest#testInlineRefusesARecapturedRead :: control :: M-INLINE-RECAPTURE',
		'unit.query.CaseCaptureTest#testInlineRefusesAnUndecidedPattern :: control :: M-INLINE-UNDECIDED',
		'unit.query.CaseCaptureTest#testOrPatternIsModelled :: control :: M-PATTERN-OR-UNMODELLED',
		'unit.query.CaseCaptureTest#testOuterBindingOfAnUndecidedCaptureRefuses :: control :: M-CAPTURE-SHADOWS-OUTER',
		'unit.query.CaseCaptureTest#testRenameLeavesTheCaptureAlone :: control :: M-CAPTURE-ARM-BIND',
		'unit.query.CaseCaptureTest#testRenameMovesEveryAlternative :: control :: M-RENAME-DECL-SELF,M-BINDING-FROM-DECL-SELF',
		'unit.query.CaseCaptureTest#testRenameRefusesAnUndecidedCapture :: control :: M-RENAME-UNDECIDED',
		'unit.query.ChangeSigSliceTest#testAReorderThatMovesTheBreakComesBackCanonical :: control :: M-SIGNATURE-EDIT-RAW-SPLICE',
		'unit.query.CliAtomicWriteSliceTest#testAFailedChangeSetRemovesTheDirectoriesItCreated :: control :: M-WRITE-DIR-KEPT',
		'unit.query.CliAtomicWriteSliceTest#testAWriteIntoAMissingDirectoryCreatesIt :: control :: M-WRITE-DIR-UNCREATED',
		'unit.query.CodepointIndexTest#testAWideCodepointCountsTwoNativeUnits :: control :: M-CODEPOINT-NATIVE,M-CODEPOINT-BACK',
		'unit.query.CommentOwnerGuardSliceTest#testACarryDeclarationThatDoesNotHoldIsNotARefusal :: control :: M-COMMENT-CARRY-REFUSES',
		'unit.query.CommentOwnerGuardSliceTest#testACommentThatKeepsItsPlaceUnderACarryIsAccepted :: control :: M-CARRY-CROSSING-ANY-SIDE',
		'unit.query.CommentOwnerGuardSliceTest#testHoistingACommentPastSurvivingCodeIsRefused :: control :: M-COMMENT-WELD-BLIND',
		'unit.query.CommentOwnerGuardSliceTest#testHoistingAcrossADeclaredCarryIsRefused :: guard :: M-COMMENT-HOIST-BLIND',
		'unit.query.CommentOwnerGuardSliceTest#testWeldingTwoCommentBlocksIsRefused :: control :: M-COMMENT-WELD-BLIND',
		'unit.query.CommentRewriteSliceTest#testAGrownPlainBlockWrapsWithoutAGutter :: control :: M-COMMENT-CONTINUATION-ALWAYS-GUTTER',
		'unit.query.CommentRewriteSliceTest#testALongFirstTokenIsWrappedNotRefused :: control :: M-COMMENT-REFLOW-COUNT-ONLY',
		'unit.query.CommentRewriteSliceTest#testAOneLineDocOverByItsCloserIsReflowedNotRefused :: control :: M-COMMENT-REFLOW-TAIL-UNSEEN',
		'unit.query.CommentRewriteSliceTest#testARunLineMayNotLoseItsOpener :: control :: M-COMMENT-RUN-OPENER-UNGUARDED',
		'unit.query.CommentRewriteSliceTest#testASuppressionDirectiveIsNeverWrapped :: control :: M-COMMENT-REFLOW-UNSAFE-LINES',
		'unit.query.CommentRewriteSliceTest#testATrailingCommentIsNeverWrapped :: control :: M-COMMENT-REFLOW-TRAILING-WRAPPED',
		'unit.query.CommentRewriteSliceTest#testBlockCommentKeepsAnInteriorLineCommentMarker :: control :: M-COMMENT-MARKER-FORCED',
		'unit.query.CommentRewriteSliceTest#testDeletingTheFirstBulletMayNotTakeTheListsOwnSeparator :: control :: '
			+ 'M-COMMENT-PARAGRAPH-DELETION-EXEMPT',
		'unit.query.CommentRewriteSliceTest#testDeletingWithATrailingSpaceTakesTheOrdinaryBreak :: guard :: ',
		'unit.query.CommentRewriteSliceTest#testFindSpanningABlankDocLineIsRefused :: control :: M-COMMENT-PARAGRAPH-UNGUARDED',
		'unit.query.CommentRewriteSliceTest#testFindSpanningABlankRunLineIsRefused :: control :: M-COMMENT-PARAGRAPH-UNGUARDED',
		'unit.query.CommentRewriteSliceTest#testJoinedDocLineIsReflowed :: control :: M-COMMENT-REFLOW-ABSENT',
		'unit.query.CommentRewriteSliceTest#testJoinedRunLineIsReflowed :: control :: M-COMMENT-REFLOW-ABSENT',
		'unit.query.CommentRewriteSliceTest#testLeadingBreakSpaceKeepsTheLineBreak :: control :: M-COMMENT-BOUNDARY-BREAK-KEPT',
		'unit.query.CommentRewriteSliceTest#testLeadingBreakSpaceWithGutterlessReplacement :: control :: M-COMMENT-BOUNDARY-BREAK-KEPT',
		'unit.query.CommentRewriteSliceTest#testLineCommentRunMatchesAcrossItsLines :: control :: M-COMMENT-RUN-PER-TOKEN',
		'unit.query.CommentRewriteSliceTest#testParagraphBreakSurvivesALeadingBreakSpaceFind :: control :: M-COMMENT-BOUNDARY-BREAK-KEPT',
		'unit.query.CommentRewriteSliceTest#testReflowBalancesRatherThanFillingToTheLimit :: control :: M-COMMENT-REFLOW-GREEDY',
		'unit.query.CommentRewriteSliceTest#testReflowLeavesAnUntouchedWideLineAlone :: control :: M-COMMENT-REFLOW-TOUCHED-ONLY',
		'unit.query.CommentRewriteSliceTest#testStructuralCommentLinesAreNeverWrapped :: control :: M-COMMENT-REFLOW-UNSAFE-LINES',
		'unit.query.CommentRewriteSliceTest#testTheRepairTriggerCountsTheCloserToo :: control :: M-COMMENT-REFLOW-TRIGGER-TAIL-UNSEEN',
		'unit.query.CommentRewriteSliceTest#testTrailingBreakSpaceKeepsTheLineBreak :: control :: M-COMMENT-BOUNDARY-TRAIL-INDEX',
		'unit.query.CommentWeldDeletionSliceTest#testHoistingInsideAReplacementIsStillRefused :: control :: M-COMMENT-WELD-BLIND',
		'unit.query.CommentWeldDeletionSliceTest#testWeldingAcrossTheRepeatedSeparatorIsStillRefused :: control :: M-COMMENT-WELD-BLIND',
		'unit.query.CompilerFactsTest#testADumpHoldingARecordNoReaderKnowsContributesNothing :: control :: M-FACTS-RECORD-KIND',
		'unit.query.CompilerFactsTest#testADumpWithoutItsClosingRecordContributesNothing :: control :: M-FACTS-INCOMPLETE',
		'unit.query.CompilerFactsTest#testARangeMeetingANodeWithAMarkerNoReaderKnowsIsUnknown :: control :: M-FACTS-WITHIN-MARKER-UNKNOWN',
		'unit.query.CompilerFactsTest#testASplicedFactRunsAtTheSitesOfTheCallThatSplicedItIn :: control :: M-FACTS-SPLICE-SITES-MET,'
			+ 'M-FACTS-SPLICE-UNATTRIBUTED,M-FACTS-SPLICE-HARMLESS,M-FACTS-SPLICE-INNERMOST,M-FACTS-SPLICE-SECOND-SITE',
		'unit.query.CondBranchSplitTest#testARebuiltNodeKeepsItsTypeArgumentCount :: control :: M-CONDBRANCH-TYPE-ARGS-DROPPED',
		'unit.query.CondQueryTest#testABranchBodyNeverCarriesADirective :: control :: M-COND-BODY-SWALLOWS-DIRECTIVES',
		'unit.query.CondQueryTest#testAMetadataNameIsASymbolRowAndKeepsItsSigil :: control :: M-COND-NAMES-DROP-META-NAME',
		'unit.query.CondQueryTest#testANestedRegionRunsInsideItsParentBranch :: control :: M-COND-INNERMOST-FRAME',
		'unit.query.CondQueryTest#testARawExpressionSpliceIsFlaggedAndKeepsItsBytes :: control :: M-COND-RAW-NEVER-MARKED',
		'unit.query.CondQueryTest#testAWholeStringLiteralKindIsDroppedByItsDeclaration :: control :: M-COND-NAMES-WHOLE-LITERAL-KEPT',
		'unit.query.CondQueryTest#testNamesInReportsSymbolsAndNotLiteralContent :: control :: M-COND-NAMES-LITERAL-TEXT-KEPT',
		'unit.query.CondRegionKindDerivationTest#testAModelledRegionStaysInvisibleToTheGate :: guard :: ',
		'unit.query.CondRegionKindDerivationTest#testEveryDirectiveAwareTerminalCarriesItsMarker :: guard :: ',
		'unit.query.CondRegionKindDerivationTest#testTheConditionalVocabularyIsTheRawCaptureOneWidened :: control :: '
			+ 'M-COND-REGION-KINDS-HARDCODED',
		'unit.query.CondRegionKindDerivationTest#testTheDerivedOpaqueKindsMatchAnIndependentScanOfTheGrammar :: control :: '
			+ 'M-COND-KIND-NAME-CONVENTION,M-OPAQUE-REGION-HAND-LIST',
		'unit.query.CondRegionKindDerivationTest#testTheMetadataPrefixedSpliceIsSeenByTheGate :: control :: M-OPAQUE-REGION-HAND-LIST',
		'unit.query.CondRegionKindDerivationTest#testTheReturnExpressionSpliceIsSeenByTheGate :: control :: M-OPAQUE-REGION-HAND-LIST',
		'unit.query.CondRegionKindDerivationTest#testTheReturnStatementSpliceIsSeenByTheGate :: control :: M-OPAQUE-REGION-HAND-LIST',
		'unit.query.CondRegionLivenessTest#testAVersionDefineComparesAsANumber :: control :: M-COND-VALUES-NUMBER,M-COND-VALUES-READ',
		'unit.query.CondRegionLivenessTest#testAnUndefinedDefineMakesAComparisonFalseAndItsNegationTrue :: control :: '
			+ 'M-COND-VALUES-UNDEFINED',
		'unit.query.CondRegionLivenessTest#testDeadSpansAreWhatNoConfigurationCompiles :: control :: M-LIVENESS-DEAD',
		'unit.query.CondRegionLivenessTest#testTwoStringsCompareByTheirCharacters :: control :: M-COND-VALUES-TEXT',
		'unit.query.CondRegionLivenessTest#testVersionsCompareBySemVerPrecedence :: control :: M-COND-VALUES-SEMVER',
		'unit.query.CreatingFixContractTest#testACreateRefusesAPathThatIsAlreadyThere :: guard :: ',
		'unit.query.CreatingFixContractTest#testACreateRefusesContentTheWriterCannotSettle :: guard :: ',
		'unit.query.CreatingFixContractTest#testACreateSettlesItsTextAtTheWriterFixedPoint :: guard :: ',
		'unit.query.CreatingFixContractTest#testAPassSeesTheChainAPreviousPassWrote :: control :: M-AMBIENT-CHAIN-STALE',
		'unit.query.CreatingFixContractTest#testDeletingACreatedFileToleratesOneAlreadyGone :: guard :: ',
		'unit.query.CrossRenamePositionTest#testAccessGrantOfARootTypeRenames :: control :: M-XREN-GRANT-UNREAD',
		'unit.query.CrossRenamePositionTest#testAccessGrantOfASubModuleTypeNamesItsTypePath :: control :: '
			+ 'M-XREN-GRANT-UNREAD,M-XREN-GRANT-MODULE-PATH',
		'unit.query.CrossRenamePositionTest#testAliasedImportPathRenames :: control :: '
			+ 'M-XREN-ALIAS-NAME-READ,M-XREN-THROUGH-IMPORT-UNREAD',
		'unit.query.CrossRenamePositionTest#testImportThroughAnotherModuleIsNotRenamed :: control :: M-XREN-THROUGH-NO-DOT',
		'unit.query.CrossRenamePositionTest#testImportThroughTheTypeRenames :: control :: M-XREN-THROUGH-IMPORT-UNREAD',
		'unit.query.CrossRenamePositionTest#testNonGrantMetadataIsNotRenamed :: control :: M-XREN-GRANT-ANY-META',
		'unit.query.CrossRenamePositionTest#testQualifiedStructExtensionRenames :: control :: M-XREN-EXTENDS-KIND-DROPPED',
		'unit.query.CrossRenamePositionTest#testQualifiedValueRenames :: control :: M-XREN-QUALIFIED-PATH-UNREAD',
		'unit.query.CrossRenamePositionTest#testShadowedPackageRootIsNotRenamed :: control :: M-XREN-SHADOWED-ROOT-BLIND',
		'unit.query.CrossRenamePositionTest#testStructExtensionRenames :: control :: '
			+ 'M-XREN-EXTENDS-HEAD-UNEMITTED,M-XREN-EXTENDS-KIND-DROPPED',
		'unit.query.DeclarationQueriesTest#testAMemberIsHostedWhereItsDeclarationIs :: control :: M-HOST-UNIQUE',
		'unit.query.DeclarationQueriesTest#testASubtypeChainPassesItsArgumentsInItsOwnTerms :: control :: '
			+ 'M-SUBTYPE-ARGS-SUBSTITUTED,M-SUBTYPE-ARGS-ARITY,M-GRAPH-INHERITED-ARGS',
		'unit.query.DeclarationQueriesTest#testASupertypeThatMayDeclareTheMemberIsNamed :: control :: '
			+ 'M-SEAL-AMBIGUOUS,M-SEAL-UNRESOLVED-IFACE,M-SEAL-DECLARING-SUPER',
		'unit.query.DeclarationQueriesTest#testAnAliasIsFollowedThroughOneDeclarationAHop :: control :: M-ALIAS-SINGLE-DECL',
		'unit.query.DeclarationQueriesTest#testTheGraphsDeclarationQuestionsAreTheIndexs :: control :: '
			+ 'M-MEMBER-KIND-IGNORED,M-TS-PATH-DECLARED-PACKAGE',
		'unit.query.DeclarationsReadTest#testABalancedDirectiveRegionIsJumpedOver :: control :: M-SKIM-NEVER',
		'unit.query.DeclarationsReadTest#testABodyIsJumpedToItsMatchingCloseOverEveryNonCodeRegion :: control :: M-SKIM-GAPS-COUNTED',
		'unit.query.DeclarationsReadTest#testABodyTheGrammarCannotReadDoesNotHideTheDeclarations :: control :: M-SKIM-NEVER',
		'unit.query.DeclarationsReadTest#testABranchThatDoesNotReturnToItsDepthIsNotSkipped :: control :: M-SKIM-BRANCH-DEPTH',
		'unit.query.DeclarationsReadTest#testADirectiveOfARegionOpenedOutsideIsNotSkipped :: control :: M-SKIM-OUTER-REGION',
		'unit.query.DeclarationsReadTest#testARegionStillOpenAtTheCloseIsNotSkipped :: control :: M-SKIM-REGION-LEFT-OPEN',
		'unit.query.DeclarationsReadTest#testAnUnclosedBodyIsNotSkipped :: guard :: ',
		'unit.query.DeclarationsReadTest#testTheDeclarationsReadAgreesWithTheFullReadOnEverySource :: guard :: ',
		'unit.query.DeclaredNullityTest#testAbstractOverClassIsProven :: control :: M-NULLITY-HOPS-CUT',
		'unit.query.DeclaredNullityTest#testAbstractOverNullIsUnproven :: control :: M-NULLITY-UNDERLYING-TRUSTED',
		'unit.query.DeclaredNullityTest#testAliasOfClassIsProven :: control :: M-NULLITY-HOPS-CUT',
		'unit.query.DeclaredNullityTest#testAliasOfUnindexedTypeIsUnproven :: control :: M-BINDING-UNINDEXED-IMPORT-FREE',
		'unit.query.DeclaredNullityTest#testAnonymousStructureTypedefIsProven :: control :: M-NULLITY-ANON-REFUSED',
		'unit.query.DeclaredNullityTest#testClassTypeParameterIsUnproven :: control :: M-NULLITY-BINDING-PARAMS-DROPPED',
		'unit.query.DeclaredNullityTest#testEnumAbstractOverIntIsProven :: control :: M-NULLITY-HOPS-CUT',
		'unit.query.DeclaredNullityTest#testFunctionTypeParameterIsUnproven :: control :: M-NULLITY-BINDING-PARAMS-DROPPED',
		'unit.query.DeclaredNullityTest#testGuardedDeclarationIsUnproven :: control :: M-NULLITY-GUARD-IGNORED',
		'unit.query.DeclaredNullityTest#testHopTargetTypeParameterIsUnproven :: control :: M-NULLITY-TYPE-PARAMS-IGNORED',
		'unit.query.DeclaredNullityTest#testImportAliasOutranksSamePackageClass :: control :: M-BINDING-ALIAS-BLIND',
		'unit.query.DeclaredNullityTest#testImportOfUnindexedModuleIsUnproven :: control :: M-BINDING-UNINDEXED-MODULE-FREE',
		'unit.query.DeclaredNullityTest#testImportOfUnindexedTypeIsUnproven :: control :: M-BINDING-UNINDEXED-IMPORT-FREE',
		'unit.query.DeclaredNullityTest#testImportedClassIsProven :: control :: M-NULLITY-SCOPE-LOST',
		'unit.query.DeclaredNullityTest#testImportedTypedefOfNullIsUnproven :: control :: M-NULLITY-ALIAS-TRUSTED',
		'unit.query.DeclaredNullityTest#testModuleOwnTypeOutranksImport :: control :: M-BINDING-OWN-TIER-CUT',
		'unit.query.DeclaredNullityTest#testParameterisedTypedefOfNullIsUnproven :: control :: M-NULLITY-ALIAS-TRUSTED',
		'unit.query.DeclaredNullityTest#testParentPackageClassIsProven :: control :: M-BINDING-PACKAGE-TIER-CUT',
		'unit.query.DeclaredNullityTest#testTypedefChainToNullIsUnproven :: control :: M-NULLITY-ALIAS-TRUSTED',
		'unit.query.DeclaredNullityTest#testTypedefOfNullIsUnproven :: control :: M-NULLITY-ALIAS-TRUSTED',
		'unit.query.DeclaredNullityTest#testUnresolvableNameIsUnproven :: control :: M-NULLITY-UNRESOLVED-PROVEN',
		'unit.query.DeclaredNullityTest#testWildcardOverIndexedPackageIsProven :: control :: M-BINDING-WILDCARD-CUT',
		'unit.query.DeclaredNullityTest#testWildcardOverUnindexedPackageIsUnproven :: control :: M-BINDING-UNINDEXED-WILDCARD-FREE',
		'unit.query.DocOwnerGuardSliceTest#testAppendBeforeAClosingBraceIsAccepted :: control :: M-DOCSPLIT-OWNER-ANY',
		'unit.query.DocOwnerGuardSliceTest#testBannerCommentIsNotGuarded :: control :: M-DOCSPAN-BANNER-IS-DOC',
		'unit.query.DocOwnerGuardSliceTest#testModifierInsertOnTheOwnersLineIsAccepted :: control :: M-DOCSPLIT-BREAKLESS-TOO',
		'unit.query.DocOwnerGuardSliceTest#testReplacementStartingAtTheOwnerIsAccepted :: control :: M-DOCSPLIT-COVERING-TOO',
		'unit.query.EditJournalTest#testAMovedMemberHasNoCounterpart :: control :: M-JOURNAL-INTERIOR',
		'unit.query.EditJournalTest#testASettleBeyondWhitespaceMapsNothing :: control :: M-JOURNAL-OPAQUE',
		'unit.query.EditJournalTest#testHistoriesThatPlaceASpanApartDecline :: control :: M-JOURNAL-AGREE',
		'unit.query.EditJournalTest#testManyEditsStillMapExactly :: control :: M-JOURNAL-SHIFT',
		'unit.query.EditJournalTest#testNoRecordedHistoryMapsNothing :: control :: M-JOURNAL-RECORD-PATH',
		'unit.query.EditJournalTest#testSwappedIdenticalBodiesKeepTheirOwnIdentity :: control :: M-JOURNAL-INTERIOR',
		'unit.query.EditJournalTest#testTheCanonicalizerRecordsWhatItSettled :: control :: M-JOURNAL-RECORD',
		'unit.query.EditJournalTest#testUntouchedTextMapsByTheShiftOfTheEditsBefore :: control :: M-JOURNAL-SHIFT',
		'unit.query.EditKeepingCanonicalGateTest#testExtractSuperclassOnADriftedFileRefusesAWeld :: control :: '
			+ 'M-KEEP-CANON-FALLBACK-UNGUARDED,M-GUARDED-SPLICE-NO-REFUSAL',
		'unit.query.EditKeepingCanonicalGateTest#testTheFallbackRefusesASplitDoc :: control :: M-KEEP-CANON-FALLBACK-UNGUARDED',
		'unit.query.EditKeepingCanonicalGateTest#testTheFallbackRefusesAStrandedElse :: control :: '
			+ 'M-KEEP-CANON-FALLBACK-UNGUARDED,M-GUARDED-SPLICE-NO-REFUSAL',
		'unit.query.EditKeepingCanonicalGateTest#testTheFallbackRefusesAnEmptiedSlot :: control :: M-KEEP-CANON-FALLBACK-UNGUARDED',
		'unit.query.EditKeepingCanonicalGateTest#testTheFallbackStillSplicesAHarmlessEdit :: control :: M-GUARDED-SPLICE-ALWAYS-REFUSES',
		'unit.query.EnumValueTypeTest#testAValueWrittenWithNoTypeIsOfItsEnumAbstract :: control :: '
			+ 'M-ENUM-VALUE-UNTYPED,M-ENUM-VALUE-STATIC',
		'unit.query.EnumValueTypeTest#testEveryBranchMustDeclareTheValue :: control :: '
			+ 'M-ENUM-VALUE-EVERY-BRANCH,M-ENUM-VALUE-UNREAD-BRANCHES,M-ENUM-VALUE-GUARDED',
		'unit.query.ExtractConstantToSliceTest#testACasePatternIsRefused :: control :: M-EXTRACT-TO-CASE-PATTERN',
		'unit.query.ExtractConstantToSliceTest#testALocalInitializerMovesIntoANewModuleOfAnotherPackage :: control :: M-EXTRACT-TO-DECL-TYPE-DROPPED',
		'unit.query.ExtractConstantToSliceTest#testALocalShadowingTheTypeIsRefused :: control :: M-EXTRACT-TO-SHADOW-UNCHECKED',
		'unit.query.ExtractConstantToSliceTest#testAMetadataArgumentIsRefused :: control :: M-EXTRACT-TO-META-POSITION',
		'unit.query.ExtractConstantToSliceTest#testANonFoldingParameterDefaultIsRefused :: control :: M-EXTRACT-TO-PARAM-DEFAULT',
		'unit.query.ExtractConstantToSliceTest#testAScalarLiteralBecomesInline :: control :: M-EXTRACT-TO-NEVER-INLINE',
		'unit.query.ExtractConstantToSliceTest#testAWildcardImportForcesTheExplicitOne :: control :: M-EXTRACT-TO-WILDCARD-IGNORED',
		'unit.query.ExtractConstantToSliceTest#testAnArrayOfANonConstantIsRefused :: control :: M-EXTRACT-TO-ANY-AGGREGATE',
		'unit.query.ExtractConstantToSliceTest#testAnInterfaceIsRefusedAsAHost :: control :: M-EXTRACT-TO-ANY-HOST',
		'unit.query.ExtractConstantToSliceTest#testAnOperatorExpressionIsNotInlined :: control :: M-EXTRACT-TO-ALWAYS-INLINE',
		'unit.query.ExtractConstantToSliceTest#testAnUnseenDeclaredTypeIsRefusedUnlessAnnotated :: control :: M-EXTRACT-TO-UNSEEN-TYPE',
		'unit.query.ExtractConstantToSliceTest#testAnUnsharedArrayIsRefused :: control :: M-EXTRACT-TO-SHARED-IGNORED',
		'unit.query.ExtractConstantToSliceTest#testAnotherImportOfTheNameIsRefused :: control :: M-EXTRACT-TO-REBIND-UNCHECKED',
		'unit.query.ExtractConstantToSliceTest#testAnotherPackageNeedsTheImport :: control :: M-EXTRACT-TO-ALWAYS-BARE',
		'unit.query.ExtractConstantToSliceTest#testReadingALocalIsRefused :: control :: M-EXTRACT-TO-READS-UNCHECKED',
		'unit.query.ExtractConstantToSliceTest#testTheEnclosingTypeKeepsItPrivate :: control :: M-EXTRACT-TO-ALWAYS-PUBLIC',
		'unit.query.ExtractInterfaceSliceTest#testAlreadyImplementsRefused :: control :: M-EI-DUP-IMPL-ALLOWED',
		'unit.query.ExtractInterfaceSliceTest#testGuardedImplementsRefused :: control :: M-EI-DUP-IMPL-ALLOWED,M-EI-GUARD-FLAT-SCAN',
		'unit.query.ExtractInterfaceSliceTest#testQualifiedSameNameDoesNotBlock :: control :: M-EI-IMPL-ANY-REFUSED',
		'unit.query.ExtractInterfaceSliceTest#testSecondInterfaceStillExtracts :: control :: M-EI-IMPL-ANY-REFUSED',
		'unit.query.ExtractMethodSliceTest#testMemberExtractPassesReadLocalsAndReturnsOne :: control :: M-EXTRACT-MEMBER-IGNORED',
		'unit.query.ExtractMethodSliceTest#testMemberExtractRefusesAHostItCannotCopyFrom :: control :: M-EXTRACT-MEMBER-TYPE-PARAMS-BLIND',
		'unit.query.ExtractMethodSliceTest#testMemberExtractRefusesALocalTheFunctionAssigns :: control :: M-EXTRACT-MEMBER-COPIES-ASSIGNED',
		'unit.query.ExtractMethodSliceTest#testMemberExtractRefusesAnUntypedOrOptionalLocal :: control :: '
			+ 'M-EXTRACT-MEMBER-WRITTEN-TYPE-TRUSTED',
		'unit.query.ExtractMethodSliceTest#testMemberExtractStaticWithStructReturn :: control :: M-EXTRACT-MEMBER-STATIC-LOST',
		'unit.query.FieldRefScanTest#testEveryBinderSpellingIsFoundFromSource :: control :: M-BINDER-KINDS-PARAMS-ONLY',
		'unit.query.FieldRefScanTest#testEveryFunctionScopeSpellingIsRecognisedFromSource :: control :: M-FN-SCOPE-KINDS-DROPS-METHODS',
		'unit.query.FieldRefScanTest#testTheScopeAndBinderVocabulariesFollowTheShapeTheyAreHanded :: control :: M-FN-SCOPE-KINDS-FROZEN',
		'unit.query.GreedyDeclSpanEditBoundarySliceTest#testAGreedyModuleDeclSpanIsTrimmedToItsOwnLastToken :: control :: '
			+ 'M-DECL-EDIT-SPAN-UNTRIMMED',
		'unit.query.HaxelibResolverTest#testAMultiLibraryAnswerSplitsOneRootPerLibrary :: control :: M-HAXELIB-BATCH-COUNT-IGNORED',
		'unit.query.ImplicitSitesTest#testAConstructionLandsItsValueArgumentsOnly :: control :: M-LANDING-TYPE-ARGS-AS-VALUES',
		'unit.query.IndexScopeTest#testAChangedSourceIsRebuilt :: control :: M-INDEX-MEMO-UNVALIDATED',
		'unit.query.IndexScopeTest#testTheKeyTellsEveryFileSetApart :: control :: M-INDEX-KEY-UNPREFIXED,M-INDEX-MEMO-TAG-IGNORED',
		'unit.query.IndexScopeTest#testTheMemoDiesWithTheAmbientChain :: control :: M-INDEX-MEMO-OUTLIVES-AMBIENT',
		'unit.query.IndexScopeTest#testTheReportIndexIsBuiltOncePerFileSet :: control :: M-INDEX-MEMO-OFF,M-INDEXSCOPE-HOST-IGNORED',
		'unit.query.IndexScopeTest#testTheReportWriteIndexIsBuiltOncePerFileSet :: control :: M-WRITE-INDEX-MEMO-OFF',
		'unit.query.IndexScopeTest#testWithoutAScopeEveryQuestionSharesTheReportBuild :: control :: M-INDEXSCOPE-RESOLUTION-OWN-BUILD',
		'unit.query.JsonQueryPluginTest#testAMemberIsNamedByItsKey :: control :: M-QUERY-NAME-IGNORED',
		'unit.query.JsonQueryPluginTest#testAPatternStringCanBeAMetavariable :: control :: M-JSON-PATTERN-NO-METAVAR',
		'unit.query.JsonQueryPluginTest#testTheLexicalRegionsAreTheStrings :: control :: M-JSON-REGIONS-NONE',
		'unit.query.JsonQueryPluginTest#testTheRootSpanIsTight :: control :: M-JSON-ROOT-UNTIGHTENED',
		'unit.query.LintBaselineTest#testAFindingThatONLYMOVEDIsNotNew :: control :: M-LINT-BASELINE-NO-SUBTRACTION',
		'unit.query.LintBaselineTest#testAFindingWithDataKeysByItsIdentity :: control :: '
			+ 'M-BASELINE-DATA-IGNORED,M-LINTDIFF-DATA-IGNORED,M-LINTFORMAT-NO-DATA',
		'unit.query.LintBaselineTest#testAnOldSnapshotIsSpentByMessage :: control :: M-BASELINE-NO-MESSAGE-FALLBACK',
		'unit.query.LintBaselineTest#testTheBaselineSpendsLikeTheDiffInAnyOrder :: control :: M-BASELINE-ONE-PASS',
		'unit.query.LintDiffTest#testAddedMinusRemovedIsAlwaysTheTotalDelta :: control :: M-LINTDIFF-SURPLUS-BY-KEY',
		'unit.query.LintDiffTest#testAnOldSnapshotPairsByMessage :: control :: M-LINTDIFF-NO-PAIRING',
		'unit.query.LintDiffTest#testAnOldSnapshotPairsEveryMessageOfOneKey :: control :: M-LINTDIFF-FIRST-MESSAGE',
		'unit.query.LintDiffTest#testDataKeyedFindingsIgnoreTheMessage :: control :: M-LINTDIFF-DATA-IGNORED',
		'unit.query.LintDiffTest#testParseReportReadsTheEnvelopeAndRefusesOtherObjects :: control :: M-LINTDIFF-ENVELOPE-REFUSED',
		'unit.query.LintDiffTest#testTheByRuleSummaryNamesEveryRuleThatMoved :: control :: M-LINTDIFF-RULE-SUMMARY-BLANK',
		'unit.query.LintDiffTest#testTheHeadlineStatesTheNetDirection :: control :: M-LINTDIFF-NET-UNSTATED',
		'unit.query.LintScoreTest#testAPipeInsideAPartIsNoCollision :: control :: M-SCORE-UNIQUE-JOINED,M-SCORE-DUPOF-AMBIGUOUS',
		'unit.query.LintScoreTest#testAnUnknownSeverityIsRefused :: control :: M-SCORE-SEVERITY-UNKNOWN',
		'unit.query.LintScoreTest#testExitStatusIsTheLostRecall :: control :: M-SCORE-LOST-EXIT',
		'unit.query.LintScoreTest#testFindingsMeetEntriesByKey :: control :: M-SCORE-DUPLICATES-AS-KEYS',
		'unit.query.LintScoreTest#testNothingToScoreIsRefused :: control :: M-SCORE-NOTHING-SCORED',
		'unit.query.LintScoreTest#testPrecisionLeavesUnknownAndUnlabelledOut :: control :: M-SCORE-PRECISION-COUNTS-UNKNOWN',
		'unit.query.LintScoreTest#testRecallCountsMarkedEntries :: control :: M-SCORE-RECALL-REAL-LONG-ONLY',
		'unit.query.LintScoreTest#testRenderAndJson :: control :: M-SCORE-JSON-EXCLUDED',
		'unit.query.LintScoreTest#testSeverityIsAMinimum :: control :: M-SCORE-SEVERITY-EXACT',
		'unit.query.LintScoreTest#testValidationRefusesWhatTheSchemaCannot :: control :: '
			+ 'M-SCORE-VERDICT-UNCHECKED,M-SCORE-DUPOF-DANGLING,M-SCORE-RECALL-FALSE-REAL-LONG',
		'unit.query.LiteralClassificationTest#testAKindNamedLikeALiteralIsNotClassifiedAsOne :: control :: M-SAFE-KINDS-SUFFIX-STUB',
		'unit.query.LiteralClassificationTest#testAnAllocatingLiteralIsRefusedByEveryPredicate :: control :: M-PURE-ARG-ROOT-ONLY',
		'unit.query.LiteralClassificationTest#testEveryDeclaredConstantLiteralIsClassifiedByEveryList :: control :: '
			+ 'M-NON-NULL-RHS-DROP-HEX',
		'unit.query.LiteralClassificationTest#testThePlainLiteralPredicateFollowsTheVocabularyItIsHanded :: control :: '
			+ 'M-PLAIN-LITERAL-FROZEN',
		'unit.query.LiteralClassificationTest#testTheRootVocabulariesFollowTheShapeTheyAreHanded :: control :: '
			+ 'M-PAREN-FREE-ROOTS-ATOMS-ONLY',
		'unit.query.LiteralClassificationTest#testTheSideEffectFreeVocabularyFollowsTheOperatorsItIsHanded :: control :: '
			+ 'M-SIDE-EFFECT-FREE-DROPS-OPERATORS',
		'unit.query.LiteralClassificationTest#testTheStringValueSeamAnswersBothSpellingsFromTheShape :: control :: '
			+ 'M-PLAIN-STRING-VALUE-NO-DELIMITERS',
		'unit.query.LiteralVocabularyTest#testAnExactQueryReachesContentInsideTheQuotes :: control :: M-LIT-DELIMITERS-IGNORED',
		'unit.query.LiteralVocabularyTest#testInertRegionsMasksWhatTheGrammarDeclaresInert :: control :: M-INERT-REGIONS-HARDCODED-KINDS',
		'unit.query.LiteralVocabularyTest#testOneContentQueryAnswersBothQuoteSpellings :: control :: M-LIT-CONTENT-KINDS-SEGMENT-ONLY',
		'unit.query.LiteralVocabularyTest#testTheContentSetFollowsTheVocabularyItIsHanded :: control :: M-LIT-CONTENT-KINDS-FROZEN',
		'unit.query.LiteralVocabularyTest#testTheInertSegmentKindsComeFromTheShapeToo :: control :: M-INERT-SEGMENT-KINDS-HARDCODED',
		'unit.query.MakeFinalSliceTest#testHalfIteratorShapeStillFinal :: control :: M-STRUCT-BUILTIN-BY-NAME',
		'unit.query.MemberReachFactsTest#testABindingOfAnOperandWrittenBeforeAnotherOperatorIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-BINDING-TRIMMED',
		'unit.query.MemberReachFactsTest#testABodyHoldingADirectiveIsReadFromTheFactsOfTheListedBuilds :: control :: '
			+ 'M-FACTS-TRUTH-CONDITIONAL,M-FACTS-TRUTH-CONDITIONAL-ALWAYS',
		'unit.query.MemberReachFactsTest#testABoundMethodRunsWheneverItsClosureIsCalled :: control :: M-FACTS-REACH-BIND',
		'unit.query.MemberReachFactsTest#testABuildMacroOnlyTheCompilerSawChangingNothingIsNoneUnderTheTruth :: control :: '
			+ 'M-REACH-REWRITTEN-TRUTH',
		'unit.query.MemberReachFactsTest#testABuildMacroOnlyTheCompilerSawIsUnknown :: control :: '
			+ 'M-FACTS-REACH-BUILDS,M-REACH-REWRITTEN-UNTRUE',
		'unit.query.MemberReachFactsTest#testACallAChainOfTargetNamesMakesIsItsTargetCodesUnderTheTruth :: control :: '
			+ 'M-GRAPH-FACTS-NATIVE-CHAIN-SKIP,M-GRAPH-FACTS-NATIVE-CHAIN-ANY',
		'unit.query.MemberReachFactsTest#testACallOfAConstructorParameterRunsWhatItsConstructionsHandIt :: control :: M-VALUE-CTOR-ROUTE',
		'unit.query.MemberReachFactsTest#testACallOfADynamicMethodRunsAnyValueWhenAStoreIsNotKnown :: control :: '
			+ 'M-VALUE-STORED-UNTYPED,M-VALUE-STORED-NATIVE,M-VALUE-CTOR-REFLECTIVE,M-VALUE-ESCAPED-SENTINEL,M-VALUE-STORED-WRITES,'
			+ 'M-VALUE-STORED-OWN,M-VALUE-CTOR-SUBTYPES,M-VALUE-CTOR-ARGUMENT,M-VALUE-CTOR-SKIPPED,M-VALUE-CTOR-REFLECTIVE-ARGS',
		'unit.query.MemberReachFactsTest#testACallOfADynamicMethodRunsOnlyTheValuesStoredIntoItUnderTheTruth :: control :: '
			+ 'M-REACH-VALUE-STORED,M-GRAPH-FACTS-VALUE-STORED,M-VALUE-CTOR-ARITY,M-VALUE-STORED-COMPUTED,M-VALUE-ESCAPED-ONLY,'
			+ 'M-VALUE-CTOR-REFLECTIVE-CLASS',
		'unit.query.MemberReachFactsTest#testACallOfAFunctionValueRunsAFunctionOfAMatchingType :: control :: M-VALUE-TYPE-FLOWS',
		'unit.query.MemberReachFactsTest#testACallOfAFunctionValueRunsAFunctionValueThatEscaped :: control :: '
			+ 'M-VALUE-TYPE-ESCAPED,M-ESCAPES-FUNCTION-RECORDED',
		'unit.query.MemberReachFactsTest#testACallOfAFunctionValueRunsAMethodReadByAName :: control :: '
			+ 'M-VALUE-TYPE-UNTYPED,M-ADMIT-OBTAINED,M-REACH-READ-BY-NAME',
		'unit.query.MemberReachFactsTest#testACallOfAFunctionValueRunsOnlyTheFunctionsItsTypeAdmitsUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FUNCTION-FLOW-TYPED',
		'unit.query.MemberReachFactsTest#testACallOfAFunctionValueRunsWhatAnInitializerABindOrAGenericBodyHandsIt :: control :: '
			+ 'M-VALUE-TYPE-GENERIC,M-VALUE-TYPE-BIND',
		'unit.query.MemberReachFactsTest#testACallOfAParameterOfAMethodInvokedOtherwiseRunsWhatItsTypeAdmits :: control :: '
			+ 'M-VALUE-ARG-WRITTEN,M-VALUE-ARG-ESCAPED,M-VALUE-ARG-SUPERTYPES,M-VALUE-ARG-COUNT,M-VALUE-ARG-LAMBDA',
		'unit.query.MemberReachFactsTest#testACallOfAParameterRunsOnlyTheFunctionsItsInvocationsHandItUnderTheTruth :: control :: '
			+ 'M-GRAPH-FACTS-VALUE-CALLED,M-REACH-VALUE-CALLED',
		'unit.query.MemberReachFactsTest#testACallOfATypeTheIndexDoesNotHoldIsNoCallOfItsNamesakeUnderTheTruth :: control :: '
			+ 'M-FACTS-UNHELD-CALL,M-FACTS-UNHELD-UNTRUE',
		'unit.query.MemberReachFactsTest#testACallOfAValueAdmitsTheValueChannel :: control :: M-FACTS-REACH-VALUE',
		'unit.query.MemberReachFactsTest#testACallOfAValueRunsOnlyTheImplicitCallsOfTheCodeItRunsUnderTheTruth :: control :: '
			+ 'M-REACH-RUN-EDGES,M-REACH-RUN-LOAD,M-REACH-RUN-VALUE-FILES,M-REACH-RUN-SITES,M-REACH-RUN-ALWAYS,M-REACH-RUN-IDS,'
			+ 'M-REACH-RUN-UNREAD',
		'unit.query.MemberReachFactsTest#testACallOfAnAbstractsConstructorIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-ABSTRACT-CTOR-CALL',
		'unit.query.MemberReachFactsTest#testACalleeABuildMacroRewroteToTouchTheMemberReachesItUnderTheTruth :: control :: '
			+ 'M-FACTS-OWNER-IDS,M-GRAPH-ADOPT-NONE,M-GRAPH-ADOPT-UNRECORDED,M-TOUCH-ADOPTED-SYNTAX',
		'unit.query.MemberReachFactsTest#testACalleeEveryListedBuildTypesIsReadFromTheirFacts :: control :: M-FACTS-TRUTH-CONTEXT',
		'unit.query.MemberReachFactsTest#testACalleeTypedDifferentlyInAnotherBuildKeepsTheSyntax :: control :: '
			+ 'M-FACTS-REACH-ALIKE,M-FACTS-TRUTH-CONTEXT-ALWAYS',
		'unit.query.MemberReachFactsTest#testAClassAComputedNameMakesIsOneTheProjectDeclaresUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-DECLARED-ANY,M-ESCAPES-FACTS-DECLARED-NONE,M-ESCAPES-FACTS-DECLARED-PRODUCED',
		'unit.query.MemberReachFactsTest#testAClassAProducerNamesEscapesUnderTheTruth :: control :: M-ESCAPES-FACTS-PRODUCED',
		'unit.query.MemberReachFactsTest#testAClosedExternRunsWhatAProgramSubclassOverridesUnderTheTruth :: control :: '
			+ 'M-REACH-CLOSED-EXTERN-OVERRIDE',
		'unit.query.MemberReachFactsTest#testAComputedNameOnAStructureTheCodeBuiltReachesNoClassUnderTheTruth :: control :: '
			+ 'M-REFLECTED-FRESH,M-REFLECTED-FRESH-PLAIN,M-FACTS-REFL-FRESH,M-FACTS-REFL-FRESH-LOCAL,M-FACTS-REFL-FRESH-WRITTEN,'
			+ 'M-FACTS-REFL-FRESH-ANY',
		'unit.query.MemberReachFactsTest#testAComputedNameOnAnObjectOfNoClassReachesOnlyAnEscapedClassUnderTheTruth :: control :: '
			+ 'M-REFLECTED-CLASSLESS,M-REFLECTED-CLASSLESS-ESCAPES,M-CLASSLESS-STRUCTURE,M-CLASSLESS-CATCH-ALL,M-CLASSLESS-NULLABLE,'
			+ 'M-CLASSLESS-TYPEDEF,M-REFLECTED-CLASSLESS-PLAIN',
		'unit.query.MemberReachFactsTest#testAComputedNameRunsOnlyAMethodOfAClassTheProjectDeclaresUnderTheTruth :: control :: '
			+ 'M-REFLECTED-HOLDERS-METHODS,M-REFLECTED-HOLDERS-ACCESSORS,M-REFLECTED-HOLDERS-INHERITED',
		'unit.query.MemberReachFactsTest#testAComputedNameStillReadsAVariableOfAnyClassWhateverTheProjectDeclaresUnderTheTruth :: '
			+ 'control :: M-HOLDERS-FIELDS-UNBOUNDED,M-GRAPH-REFLECT-SUPERTYPES',
		'unit.query.MemberReachFactsTest#testAConfigurationWithoutFactsLeavesTheSyntax :: control :: M-FACTS-REACH-DROPPED',
		'unit.query.MemberReachFactsTest#testAConstructionABuildMacroSwappedForAnotherGenericBuildIsNoTextUnderTheTruth :: control :: '
			+ 'M-FACTS-GENERIC-BUILT,M-FACTS-ROUNDS',
		'unit.query.MemberReachFactsTest#testAConstructionALiteralWritesIsItsTextUnderTheTruth :: control :: M-FACTS-TEXT-LITERAL',
		'unit.query.MemberReachFactsTest#testAConstructionOfAGenericBuildIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-GENERIC-BUILD,M-FACTS-GENERIC-RECORDED',
		'unit.query.MemberReachFactsTest#testAConstructionOfAnAbstractIsItsTextUnderTheTruth :: control :: M-FACTS-TEXT-ABSTRACT-NEW',
		'unit.query.MemberReachFactsTest#testAConstructionOfTheBuiltInArrayIsHandedNothingUnderTheTruth :: control :: '
			+ 'M-REACH-ARRAY-CTOR,M-REACH-ARRAY-OWN,M-FACTS-UNHELD-STAND-IN',
		'unit.query.MemberReachFactsTest#testAConstructionRunsTheInitializersOfItsGeneratedConstructor :: control :: '
			+ 'M-FACTS-REACH-CONSTRUCTION',
		'unit.query.MemberReachFactsTest#testAConstructionThroughATypedefIsItsTextUnderTheTruth :: control :: M-FACTS-TEXT-TYPEDEF-NEW',
		'unit.query.MemberReachFactsTest#testAConstructionThroughAnImportAliasIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-TYPEDEF-NEW',
		'unit.query.MemberReachFactsTest#testAConstructorTheCompilerMadeHandingItsParametersOnIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-MADE-FORWARDS',
		'unit.query.MemberReachFactsTest#testAConstructorTouchingItsOwnObjectIsExcusedUnderTheTruth :: control :: M-TOUCH-TYPED-SELF',
		'unit.query.MemberReachFactsTest#testAConstructorTypedAsNoFunctionAndNoEnumHoldsAnythingUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-CTOR-SHAPE',
		'unit.query.MemberReachFactsTest#testAConversionAnInlinedBodySplicedFromAnotherFileConvertsItsOwnArgumentUnderTheTruth :: '
			+ 'control :: M-FACTS-CALL-OPERAND',
		'unit.query.MemberReachFactsTest#testAConversionOfAFieldOfWhatAnInlinedIndexReturnsIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-JOINED-CONVERSION,M-FACTS-TEXT-JOINED-PLACED',
		'unit.query.MemberReachFactsTest#testAConversionOfAnAbstractRunsWhatItsOwnConversionDoes :: control :: M-REACH-ABSTRACT-TEXT-ANY',
		'unit.query.MemberReachFactsTest#testAConversionTheCompilerCallsIsItsTextUnderTheTruth :: control :: M-FACTS-TEXT-CONVERSION-CALL',
		'unit.query.MemberReachFactsTest#testAConvertedValueOfTheParametersOwnTypeMayBeAnyObjectUnderTheTruth :: control :: '
			+ 'M-FACTS-CALL-OPERAND-LEAF',
		'unit.query.MemberReachFactsTest#testACopyEachBuildReadsFromItsOwnDirectoryIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-COPY-LINE-HOME,M-FACTS-COPY-NESTED-UNION',
		'unit.query.MemberReachFactsTest#testACopyOfATypeNoBuildReadsIsNoProofUnderTheTruth :: control :: M-FACTS-COPY-UNVOUCHED',
		'unit.query.MemberReachFactsTest#testACopyTheIndexDoesNotHoldIsNoProofUnderTheTruth :: control :: M-REACH-COPY-ELSEWHERE',
		'unit.query.MemberReachFactsTest#testACoreTypeAsAValueHoldsNothingUnderTheTruth :: control :: M-ESCAPES-FACTS-ABSTRACT-REFUSED',
		'unit.query.MemberReachFactsTest#testADeclaredGlobMatchesTheClassItselfByItsQualifiedNameUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-DECLARED-SUBTYPES,M-GLOB-QUALIFIED-SEGMENT',
		'unit.query.MemberReachFactsTest#testADeclaredMethodHolderIsMatchedByTheClassOfTheObjectItselfUnderTheTruth :: control :: '
			+ 'M-METHODS-HOLDERS-OWN-NAME',
		'unit.query.MemberReachFactsTest#testAFieldAccessTheFactsReaderDoesNotKnowIsUnresolvedUnderTheTruth :: control :: '
			+ 'M-GRAPH-FIELD-ACCESS-UNKNOWN',
		'unit.query.MemberReachFactsTest#testAFieldInitializerIsReadThroughItsFactsUnderTheTruth :: control :: '
			+ 'M-GRAPH-INIT-RECORD,M-FACTS-VIEW-INIT-FACETED',
		'unit.query.MemberReachFactsTest#testAFieldReadJoinedAcrossTwoGettersInACallbackIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-WALK-JOINED-START',
		'unit.query.MemberReachFactsTest#testAFieldReadJoinedFromAnIndexAccessToTheAccessAnotherInlinedMethodWritesIsItsTextUnderTheTruth '
			+ ':: control :: M-FACTS-TEXT-JOINED-OTHER-SPLICE',
		'unit.query.MemberReachFactsTest#testAFieldSetByItsNameConvertsTheValueOnHxcppUnderTheTruth :: control :: '
			+ 'M-FACTS-CONVERSION-WRITES,M-FACTS-CONVERSION-FIELD-WRITES',
		'unit.query.MemberReachFactsTest#testAFieldTheCompilerCallsLeavesItsFunctionToTheSyntaxUnderTheTruth :: control :: '
			+ 'M-TOUCH-TYPED-CALLED',
		'unit.query.MemberReachFactsTest#testAFieldTheCompilerPlacesAcrossTwoInlinedGettersIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-JOINED-SPLICES',
		'unit.query.MemberReachFactsTest#testAFileTheRunWroteMayBeCompiled :: control :: M-FACTS-DEAD-FILE-REWRITTEN',
		'unit.query.MemberReachFactsTest#testAFreshObjectConvertedRunsOnlyItsOwnClassToStringUnderFactsThatAreNotTheTruth :: control :: '
			+ 'M-REACH-EXACT-SITE',
		'unit.query.MemberReachFactsTest#testAFreshObjectConvertedRunsOnlyItsOwnClassToStringUnderTheTruth :: control :: '
			+ 'M-FACTS-STRING-EXACT,M-FACTS-VIEW-EXACT,M-FACTS-VIEW-EXACT-CONVERSION,M-FACTS-EXACT-WRITTEN,M-FACTS-CALL-OPERAND-EXACT',
		'unit.query.MemberReachFactsTest#testAFunctionNestedInATypeOfASharedNameIsItsFilesTypesCodeUnderTheTruth :: control :: '
			+ 'M-FACTS-NESTED-OWNER-NONE,M-FACTS-NESTED-BODIES-NONE,M-REACH-OWN-TYPES-NONE,M-REACH-REWRITTEN-OWN-SIMPLE',
		'unit.query.MemberReachFactsTest#testAFunctionSplicedFromAnotherFileIsTheNodeItsCalleeDeclares :: control :: '
			+ 'M-GRAPH-FACTS-SPLICED-SITE,M-GRAPH-FACTS-SPLICED-FILE,M-FACTS-TRUTH-SPLICE',
		'unit.query.MemberReachFactsTest#testAFunctionValueReadByItsSyntaxMayRunAnyOperatorOverloadUnderTheTruth :: control :: '
			+ 'M-ADMIT-SYNTAX-READ-FACETED',
		'unit.query.MemberReachFactsTest#testAFunctionWithoutFactsOfItsOwnIsNotReadThroughANestedOnes :: control :: '
			+ 'M-FACTS-REACH-NESTED-OWNER',
		'unit.query.MemberReachFactsTest#testAGenericInstanceIsItsGenericClass :: control :: M-FACTS-REACH-GENERIC',
		'unit.query.MemberReachFactsTest#testAKeyValueLoopOverTheMemberLetsNothingEscapeUnderTheTruth :: control :: '
			+ 'M-FACTS-INLINED-RECEIVER',
		'unit.query.MemberReachFactsTest#testALibraryClassTheWalkEntersIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-PURE-CALL,M-FACTS-TEXT-ABSTRACT-NEW',
		'unit.query.MemberReachFactsTest#testALibraryDynamicMethodNotReadYetIsFollowed :: control :: M-FACTS-REACH-LIBRARY-DYNAMIC',
		'unit.query.MemberReachFactsTest#testALibraryMemberAFactCallsIsItsOwnTypesUnderTheTruth :: control :: '
			+ 'M-REACH-QUALIFIED-NONE,M-FACTS-QUALIFIED-HAZARDS,M-GRAPH-FACTS-TYPED-NONE',
		'unit.query.MemberReachFactsTest#testALibraryMemberOnlyOneTypeOfItsNameDeclaresIsReadThroughItsFacts :: control :: '
			+ 'M-FACTS-SOLE-MEMBER-NONE',
		'unit.query.MemberReachFactsTest#testALocalACalleeRebuiltInPlaceHandsOutIsNoProofUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-CALLS-ANY',
		'unit.query.MemberReachFactsTest#testALocalHoldingTheMemberThroughAValueConstructIsFollowedUnderTheTruth :: control :: '
			+ 'M-FACTS-HELD-THROUGH-IF,M-FACTS-HELD-THROUGH-SWITCH,M-FACTS-HELD-THROUGH-PAREN,M-FACTS-HELD-THROUGH-BLOCK,'
			+ 'M-FACTS-HELD-THROUGH-TRY,M-FACTS-ASSIGN-HELD-THROUGH',
		'unit.query.MemberReachFactsTest#testALocalInlineFunctionKeepsItsBodysSyntax :: control :: M-GRAPH-LOCAL-INLINE',
		'unit.query.MemberReachFactsTest#testALocalOfABodyABuildMacroReplacedIsNoProofUnderTheTruth :: control :: '
			+ 'M-REACH-ENTRY-REWRITTEN,M-REACH-ENTRY-LOCAL',
		'unit.query.MemberReachFactsTest#testALocalPlacedAtItsDeclarationsKeywordIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-DECLARES',
		'unit.query.MemberReachFactsTest#testALocalTheCompilerBindsAValueTheTextWritesToIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-BINDING',
		'unit.query.MemberReachFactsTest#testALocalTheMemberIsStoredInIsFollowedThroughItsReadsUnderTheTruth :: control :: '
			+ 'M-FACTS-ASSIGN-HELD,M-FACTS-SUBSTITUTED-RECEIVER,M-FACTS-ALIAS-LINK,M-FACTS-CAPTURE',
		'unit.query.MemberReachFactsTest#testALoopOverAProjectIteratorRunsItsNextUnderTheTruth :: control :: M-FACTS-ITER',
		'unit.query.MemberReachFactsTest#testAMacroBuiltTypeAnswersFromItsTextOnlyWhenItsFactsAreItsText :: control :: '
			+ 'M-FACTS-TEXT-SPELLED',
		'unit.query.MemberReachFactsTest#testAMacroExpansionIsAnsweredFromItsFactsUnderTheTruth :: control :: '
			+ 'M-FACTS-EXPANSION-PLACED,M-FACTS-EXPANSION-BLIND,M-GRAPH-FACTS-EXPANSION-CALL',
		'unit.query.MemberReachFactsTest#testAMacroExpansionIsUnknown :: control :: M-FACTS-REACH-MACRO',
		'unit.query.MemberReachFactsTest#testAMacroExpansionRunsItsTypedCodeAtItsCallUnderTheTruth :: control :: '
			+ 'M-TOUCH-EXPANSION-CODE,M-FACTS-WITHIN-EXPANSION-NULL',
		'unit.query.MemberReachFactsTest#testAMacroExpansionRunsWhereItsCallIsUnderTheTruth :: control :: M-FACTS-WITHIN-EXPANSION,'
			+ 'M-GRAPH-FACTS-EXPANSION-SITE,M-FACTS-EXPANSION-SPLICE-SITES,M-TOUCH-EXPANSION-RUNS,M-FACTS-WALK-BLOCK-GAP',
		'unit.query.MemberReachFactsTest#testAMarkerTheFactsReaderDoesNotKnowIsABlindSpotUnderTheTruth :: control :: '
			+ 'M-FACTS-BLIND-UNKNOWN',
		'unit.query.MemberReachFactsTest#testAMarkerTheFactsReaderDoesNotKnowIsNoTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-MARKER-UNKNOWN',
		'unit.query.MemberReachFactsTest#testAMarkerTheFactsReaderDoesNotKnowKeepsItsBodysSyntaxUnderTheTruth :: control :: '
			+ 'M-FACTS-UNPLACED-UNKNOWN',
		'unit.query.MemberReachFactsTest#testAMarkerTheFactsReaderDoesNotKnowLeavesTheMethodValuesUnknownUnderTheTruth :: control :: '
			+ 'M-METHODS-MARKER-UNKNOWN',
		'unit.query.MemberReachFactsTest#testAMarkerTheFactsReaderDoesNotKnowLeavesWhatAFunctionFieldHoldsUnknownUnderTheTruth :: '
			+ 'control :: M-VALUE-STORED-MARKER-UNKNOWN,M-VALUE-CTOR-MARKER-UNKNOWN',
		'unit.query.MemberReachFactsTest#testAMarkerTheFactsReaderDoesNotKnowLetsWhatItsNodeIsHandedEscapeUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-MARKER-UNKNOWN',
		'unit.query.MemberReachFactsTest#testAMemberAdmittedByItsNameIsNoVariableOfAnotherTypeOfTheNameUnderTheTruth :: control :: '
			+ 'M-FACTS-OWNERS-VARIABLES,M-FACTS-OWNERS-ROOTS-OWN',
		'unit.query.MemberReachFactsTest#testAMemberAnInlinedMethodTakesAsAnArgumentStillEscapesUnderTheTruth :: control :: '
			+ 'M-FACTS-RECEIVER-BLOCK,M-FACTS-RECEIVER-PARAM',
		'unit.query.MemberReachFactsTest#testAMemberAnotherBuildDeclaresShadowsAnExtension :: control :: M-FACTS-REACH-GUARDED-NAME',
		'unit.query.MemberReachFactsTest#testAMemberAnotherTypeOfItsNameMayDeclareKeepsTheNameShared :: control :: '
			+ 'M-FACTS-SOLE-MEMBER-DECLARED',
		'unit.query.MemberReachFactsTest#testAMemberDeclaredInEachBranchIsReadByIdUnderTheTruth :: control :: M-FACTS-FOLDED-BY-ID',
		'unit.query.MemberReachFactsTest#testAMemberOfWhatAnInlinedGetterReturnsIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-JOINED-ACCESS',
		'unit.query.MemberReachFactsTest#testAMemberOnlyAListedBuildDeclaresShadowsAnExtensionThere :: control :: M-FACTS-TRUTH-CONTEXT',
		'unit.query.MemberReachFactsTest#testAMemberOnlyOneTypeOfItsNameDeclaresAsksThatTypesBuildMacroUnderTheTruth :: control :: '
			+ 'M-REACH-REWRITTEN-SOLE-SIMPLE',
		'unit.query.MemberReachFactsTest#testAMethodABuildMacroAddedTheFactsCannotReadTouchesTheMemberUnderTheTruth :: control :: '
			+ 'M-TOUCH-ADOPTED-UNREAD',
		'unit.query.MemberReachFactsTest#testAMethodABuildMacroAddedTouchingTheMemberReachesItUnderTheTruth :: control :: '
			+ 'M-GRAPH-ADOPT-NONE,M-TOUCH-ADOPTED-SYNTAX',
		'unit.query.MemberReachFactsTest#testAMethodAComputedNameReadsIsOneOfAClassTheProjectDeclaresUnderTheTruth :: control :: '
			+ 'M-METHODS-HOLDERS-DECLARED,M-METHODS-HOLDERS-OBTAINED,M-HOLDERS-GRAPH',
		'unit.query.MemberReachFactsTest#testAMethodClosureOfTheMemberEscapesUnderTheTruth :: control :: '
			+ 'M-TOUCH-TYPED-VALUE,M-TOUCH-TYPED-UNTRUE',
		'unit.query.MemberReachFactsTest#testAMethodOfAnObjectThatNeverEscapedIsNoValueAComputedNameReads :: control :: '
			+ 'M-METHODS-HOLD-CLASSLESS',
		'unit.query.MemberReachFactsTest#testAMethodValueSomeCodeMayCallLeavesItsParameterUnknownUnderTheTruth :: control :: '
			+ 'M-GUARDED-NEVER-CALLED,M-GUARDED-OVERRIDES,M-GUARDED-PLAIN-CALLS,M-GUARDED-PLAIN-READS,M-GUARDED-CONTAINER,'
			+ 'M-GUARDED-CONTAINER-FRESH,M-GUARDED-CONTAINER-READS,M-GUARDED-REFLECTED,M-GUARDED-TARGET-CODE,M-GUARDED-OBTAINED,'
			+ 'M-GUARDED-MEMBER-NAME',
		'unit.query.MemberReachFactsTest#testANameTwoTypesShareReachedByItsSyntaxRunsAsEachOfThemUnderTheTruth :: control :: '
			+ 'M-REACH-QUALIFIED-UNNAMED,M-REACH-SHARED-OWNERS',
		'unit.query.MemberReachFactsTest#testANativeIdentifierAdmitsWhatItMayCall :: control :: M-FACTS-REACH-NATIVE-IDENT',
		'unit.query.MemberReachFactsTest#testANullGuardOfAParameterOnlyEverHandedNullKeepsItsBranchFromRunningUnderTheTruth :: control :: '
			+ 'M-FACTS-FRESH-MAP,M-GUARDED-AND,M-GUARDED-ELSE,M-GUARDED-HOP,M-GUARDED-ASSUMED',
		'unit.query.MemberReachFactsTest#testAParameterAnotherValueMayReachKeepsItsGuardLiveUnderTheTruth :: control :: '
			+ 'M-GUARDED-HANDS-NULL,M-GUARDED-KEPT,M-FACTS-KEPT-DEFAULT,M-FACTS-KEPT-WRITTEN,M-FACTS-KEPT-BUILDS,M-GUARDED-EQUALITY',
		'unit.query.MemberReachFactsTest#testAParameterOfAMethodOfAnEscapedObjectHoldsWhatItsCallsByNameHandItUnderTheTruth :: control :: '
			+ 'M-VALUE-ARG-ESCAPED,M-VALUE-UNTYPED-VALUE-READ,M-VALUE-UNTYPED-CALLS,M-VALUE-UNTYPED-ACCESS-UNKNOWN,M-VALUE-UNTYPED-NATIVE',
		'unit.query.MemberReachFactsTest#testAPinnedOwnerAsksItsOwnBuildMacroAndNoOtherUnderTheTruth :: control :: '
			+ 'M-REACH-PINNED-NONE,M-REACH-PINNED-REWRITTEN-SIMPLE,M-REACH-PINNED-REWRITTEN-NONE,M-FACTS-PINNED-OWNER-FILES',
		'unit.query.MemberReachFactsTest#testAProducerReadAsAValueMakesOnlyADeclaredClassUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-DECLARED-PRODUCED,M-ESCAPES-FACTS-DECLARED-READER',
		'unit.query.MemberReachFactsTest#testAProjectFileNoBuildCompilesLetsNoValueEscape :: guard :: ',
		'unit.query.MemberReachFactsTest#testAProjectFileNoBuildCompilesRunsNothing :: control :: '
			+ 'M-REACH-DEAD-FILE-SEEDS,M-FACTS-DEAD-FILE-NEVER,M-FACTS-DEAD-FILE-UNTRUE',
		'unit.query.MemberReachFactsTest#testAProofTheTruthContradictsIsAskedAgainUnderTheTruth :: control :: M-REACH-PROVEN-TRUTH',
		'unit.query.MemberReachFactsTest#testAPropertyOneBuildReadsThroughAGetterIsNotReadStraight :: control :: M-FACTS-FIELD-KINDS',
		'unit.query.MemberReachFactsTest#testAPropertyOnlyAnotherBranchsDeclarationOfATypeGivesRunsItsAccessor :: control :: '
			+ 'M-INDEX-ALTERNATE-DROPPED,M-INDEX-ALTERNATE-MEMBERS',
		'unit.query.MemberReachFactsTest#testAPropertyReadStraightFromItsStorageIsAnsweredUnderTheTruth :: control :: '
			+ 'M-REACH-PROPERTY-STRAIGHT,M-REACH-PROPERTY-GETTER,M-REACH-FACTS-FIELDS-UNTRUE',
		'unit.query.MemberReachFactsTest#testAPushThroughALocalHoldingTheMemberInsideTheRegionReachesItUnderTheTruth :: control :: '
			+ 'M-TOUCH-TYPED-HELD-REGION,M-FACTS-HELD-FLAG',
		'unit.query.MemberReachFactsTest#testARawConditionalRegionOfAFacetedFunctionIsItsFactsUnderTheTruth :: control :: '
			+ 'M-FACTS-RAW-REGION,M-FACTS-RAW-REGION-NAMES',
		'unit.query.MemberReachFactsTest#testAReadOfAnInlinedArgumentAtTheValueTheTextWritesIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-READ-AT-VALUE,M-FACTS-TEXT-INTERPOLATED-VALUE,M-FACTS-TEXT-LITERAL-END',
		'unit.query.MemberReachFactsTest#testAReflectedObjectOfExactlyItsClassIsNoSubclassUnderTheTruth :: control :: '
			+ 'M-GRAPH-REFLECT-EXACT,M-FACTS-REFL-EXACT',
		'unit.query.MemberReachFactsTest#testAReflectedObjectOtherThanThisMayBeAnyEscapedInstanceUnderTheTruth :: control :: '
			+ 'M-GRAPH-REFLECT-ESCAPES,M-GRAPH-REFLECT-SELF-ESCAPES,M-FACTS-REFL-SELF',
		'unit.query.MemberReachFactsTest#testAReflectiveAccessOnAValueOfNoClassIsADynamicNameOnceTheClassEscapedUnderTheTruth :: control '
			+ ':: M-GRAPH-REFLECT-UNTYPED',
		'unit.query.MemberReachFactsTest#testAReflectiveAccessOnAnObjectOfAnUnrelatedClassReachesNoneOfTheMemberUnderTheTruth :: control '
			+ ':: M-REACH-REFLECT-BOUND-NONE,M-HAZARDS-REFLECT-RECEIVERS,M-HAZARDS-REFLECT-RECEIVERS-ADDED,M-FACTS-REFL-RECEIVER,'
			+ 'M-REACH-REFLECT-BODY,M-REACH-REFLECT-EXTERN',
		'unit.query.MemberReachFactsTest#testAReflectiveAccessOnAnObjectThatMayCarryTheMemberIsADynamicNameUnderTheTruth :: control :: '
			+ 'M-REACH-REFLECT-RELATED,M-GRAPH-REFLECT-SUBTYPES',
		'unit.query.MemberReachFactsTest#testAReflectiveAccessRunsTheAccessorsOfTheTypeItReachesUnderTheTruth :: control :: '
			+ 'M-REACH-REFLECT-ADMIT',
		'unit.query.MemberReachFactsTest#testAReflectiveAccessSplicedInNamesTheLiteralItsNameArgumentHoldsUnderTheTruth :: control :: '
			+ 'M-FACTS-REFL-MEMBER-NAME,M-FACTS-REFL-MEMBER-NAME-ANY,M-HAZARDS-TRUTH-LITERAL-NAME,'
			+ 'M-HAZARDS-TRUTH-LITERAL-FIRST-STRING,M-EXTERN-BLIND-REFLECTIVE,M-EXTERN-BLIND-TARGET-ADMISSION',
		'unit.query.MemberReachFactsTest#testAReflectiveAccessTheSyntaxReadsAsComputedNamesTheLiteralTheTypedTreeHandsItUnderTheTruth :: '
			+ 'control :: M-HAZARDS-TRUTH-LITERAL-SEEN,M-HAZARDS-TRUTH-LITERAL-AGREE',
		'unit.query.MemberReachFactsTest#testAReflectiveCallTheSyntaxDoesNotSeeNamesNothingUnderTheTruth :: control :: '
			+ 'M-FACTS-TRUTH-REFLECTION,M-FACTS-TRUTH-REFLECTION-TWIN',
		'unit.query.MemberReachFactsTest#testAReflectiveMemberReadAsAValueIsUnknown :: control :: M-FACTS-REACH-REFLECT-VALUE',
		'unit.query.MemberReachFactsTest#testAReflectiveMemberReadAsAValueObtainsOnlyADeclaredClassesMethodsUnderTheTruth :: control :: '
			+ 'M-METHODS-HOLDERS-VALUE',
		'unit.query.MemberReachFactsTest#testAReflectiveMemberWhoseResultHoldsNoMemberValueObtainsNoMethodUnderTheTruth :: control :: '
			+ 'M-METHODS-MEMBERLESS-RESULT',
		'unit.query.MemberReachFactsTest#testARegexLiteralWithFlagsIsItsTextUnderTheTruth :: control :: M-FACTS-TEXT-LITERAL-FLAGS',
		'unit.query.MemberReachFactsTest#testARegionOfABodyABuildMacroReplacedIsNoProofUnderTheTruth :: control :: '
			+ 'M-REACH-ENTRY-REWRITTEN,M-REACH-ENTRY-MEMBER,M-REACH-TEXTUAL-ALWAYS',
		'unit.query.MemberReachFactsTest#testARegionOfATypeABuildReadsFromACopyTheIndexDoesNotHoldIsNoProofUnderTheTruth :: control :: '
			+ 'M-FACTS-COPY-UNHELD',
		'unit.query.MemberReachFactsTest#testAStoredFunctionValueMayConvertWhatItIsHanded :: control :: M-FACTS-REACH-UNREAD-VALUE',
		'unit.query.MemberReachFactsTest#testAStoredFunctionValueMayIterateWhatItHoldsUnderTheTruth :: control :: '
			+ 'M-REACH-TYPED-IMPLICIT-ITER',
		'unit.query.MemberReachFactsTest#testAStoredFunctionValueMayRunAnOperatorOverload :: control :: M-FACTS-REACH-UNREAD-IMPLICIT',
		'unit.query.MemberReachFactsTest#testAStringBufHandsItsTargetCodeNoObjectUnderTheTruth :: control :: M-NATIVE-CLASSES-EXTERN',
		'unit.query.MemberReachFactsTest#testAThisNoDeclaredClassLetsAComputedNameObtainIsBoundByItsDispatchUnderTheTruth :: control :: '
			+ 'M-METHODS-HOLDERS-SELF,M-METHODS-HOLDERS-REBIND',
		'unit.query.MemberReachFactsTest#testAThrownExceptionIsConvertedToNoString :: control :: M-FACTS-THROW-EXCEPTION',
		'unit.query.MemberReachFactsTest#testAThrownValueIsConvertedToAString :: control :: M-FACTS-THROW-TEXT,M-SITES-THROW-TEXT',
		'unit.query.MemberReachFactsTest#testATouchOnlyTheFactsSeeInASecondDeclarationIsFoundUnderTheTruth :: control :: '
			+ 'M-TOUCH-FOLDED-ACCESSES',
		'unit.query.MemberReachFactsTest#testATouchOnlyTheFactsSeeIsFoundUnderTheTruth :: control :: '
			+ 'M-TOUCH-TYPED-NEVER,M-TOUCH-TYPED-SHAPE-NONE,M-TOUCH-TYPED-CALL,M-TOUCH-TYPED-OWNER',
		'unit.query.MemberReachFactsTest#testATouchThroughAnInferredReceiverIsTypedByTheCompiler :: control :: M-FACTS-REACH-TOUCH-TYPED',
		'unit.query.MemberReachFactsTest#testATraceTheTargetLowersLetsOnlyWhatItIsHandedEscapeUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-NATIVE-REFUSED,M-ESCAPES-TRUTH-FACTS',
		'unit.query.MemberReachFactsTest#testATypeBringingExtensionsInUnderAConditionIsReadFromTheListedBuilds :: control :: '
			+ 'M-FACTS-TRUTH-CONTEXT',
		'unit.query.MemberReachFactsTest#testATypeBringingExtensionsInUnderAConditionIsUnknown :: control :: '
			+ 'M-FACTS-REACH-USING-META,M-GRAPH-USING-META,M-INDEX-GUARDED-META-LIFT',
		'unit.query.MemberReachFactsTest#testATypeCheckTheCompilerCallsIsItsTextUnderTheTruth :: control :: M-FACTS-TEXT-PURE-CALL',
		'unit.query.MemberReachFactsTest#testATypeDeclaredOncePerBuildIsOneTypeUnderTheTruth :: control :: '
			+ 'M-FACTS-FOLDED-BY-ID,M-FACTS-SOLE-NEVER,M-REACH-AMBIGUOUS-SOLE-NONE',
		'unit.query.MemberReachFactsTest#testATypeEachBuildReadsFromItsOwnCopyIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-COPY-UNION,M-FACTS-COPY-HOMED-UNION,M-FACTS-COPY-TYPE-HOMES,M-GRAPH-REFACET-FURTHER,M-GRAPH-REFACET-RETRACT',
		'unit.query.MemberReachFactsTest#testATypeInAFileImportingUnderAConditionKeepsTheSyntax :: control :: '
			+ 'M-FACTS-REACH-GUARDED-IMPORT',
		'unit.query.MemberReachFactsTest#testATypeNoBuildCompilesIsNoSecondDeclarationOfItsNameUnderTheTruth :: control :: '
			+ 'M-FACTS-IDLE-INDEX',
		'unit.query.MemberReachFactsTest#testATypeTheIndexDeclaresNowhereRunsWhatItsMembersRun :: control :: '
			+ 'M-FACTS-TEXTLESS,M-FACTS-IMPLICIT-MEMBERS,M-FACTS-IMPLICIT-STATIC,M-REACH-UNHELD-OWNED,M-REACH-UNHELD-ANYWHERE,'
			+ 'M-REACH-TEXTLESS-IN-PLAY,M-REACH-UNDECLARED-OPERAND,M-REACH-REFLECT-TEXTLESS,M-FACTS-IMPLICIT-INTERFACE',
		'unit.query.MemberReachFactsTest#testATypedCallOfAnotherClassMayRunTheMethodOfAnObjectPutThereUnderTheTruth :: control :: '
			+ 'M-VALUE-INVOKED-FOREIGN,M-VALUE-INVOKED-SUBTYPE-SUPERS,M-UNCHECKED-HOLDS',
		'unit.query.MemberReachFactsTest#testATypedWriteOfAnotherClassMayReplaceTheMethodOfAnObjectPutThereUnderTheTruth :: control :: '
			+ 'M-VALUE-STORED-FOREIGN',
		'unit.query.MemberReachFactsTest#testATypedefAliasingTheTypeElsewhereIsNoneOfItsCodeUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-ALIAS-TYPEDEF',
		'unit.query.MemberReachFactsTest#testAUseTheFactsReaderDoesNotKnowIsAnEscapeUnderTheTruth :: control :: '
			+ 'M-TOUCH-USE-UNKNOWN,M-TOUCH-USE-KNOWN-READS',
		'unit.query.MemberReachFactsTest#testAValueAGenericClassLetsGoEscapesUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-INSTANCES,M-ESCAPES-FACTS-PARAMETER',
		'unit.query.MemberReachFactsTest#testAValueAGenericMethodLetsGoEscapesUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-GENERIC-METHOD,M-FACTS-GENS',
		'unit.query.MemberReachFactsTest#testAValueFlowingIntoACatchAllEscapesUnderTheTruth :: control :: M-ESCAPES-FACTS-FLOW',
		'unit.query.MemberReachFactsTest#testAValueHandedToAnExternEscapesUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-HANDED,M-FACTS-HANDS',
		'unit.query.MemberReachFactsTest#testAValuePutAtAStringPlaceRunsItsToStringOnHxcppUnderTheTruth :: control :: '
			+ 'M-FACTS-CONVERSION-FLOWS,M-FACTS-CONVERSION-TARGET,M-FACTS-CONVERSION-ANY-TARGET,M-UNCHECKED-STRING-ELEMENTS',
		'unit.query.MemberReachFactsTest#testAVariableABuildMacroMadeAPropertyKeepsItsOwnerUnknownUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-FIELDS-ANY',
		'unit.query.MemberReachFactsTest#testAWriteOfAFieldOfAnInlinedIndexAccessIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-JOINED-SITE',
		'unit.query.MemberReachFactsTest#testAWriteTheCompilerSeesStoringOnlyFreshValuesLetsNothingEscape :: control :: '
			+ 'M-TOUCH-TYPED-FRESH,M-TOUCH-TYPED-SYNTAX-TOO',
		'unit.query.MemberReachFactsTest#testAnAbstractsConversionAnInterpolationCallsIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-CONVERTS',
		'unit.query.MemberReachFactsTest#testAnAbstractsInlineConstructorIsItsTextUnderTheTruth :: control :: M-FACTS-DECLARATION-RUN',
		'unit.query.MemberReachFactsTest#testAnAbstractsInlineConstructorIsReadFromItsFactsUnderTheTruth :: control :: '
			+ 'M-FACTS-VIEW-DECLARATION-RUN',
		'unit.query.MemberReachFactsTest#testAnAccessorCalledByItsOwnNameIsItsTextUnderTheTruth :: control :: M-FACTS-TEXT-ACCESSOR-NAME',
		'unit.query.MemberReachFactsTest#testAnAdmittedConversionOfANameTwoTypesShareIsTheOperandsTypesUnderTheTruth :: control :: '
			+ 'M-FACTS-SITE-OWNERS-NONE,M-FACTS-SITE-CONVERSION-OWNERS-NONE,M-REACH-OWNED-TYPES-NONE,M-REACH-OWNED-UNTYPED,'
			+ 'M-REACH-OWNED-ESCAPES-KEPT',
		'unit.query.MemberReachFactsTest#testAnArgumentAMethodKeepsNothingOfLetsNothingEscapeUnderTheTruth :: control :: '
			+ 'M-FACTS-ARGUMENT-USE,M-FACTS-PARAM-ALIAS,M-ARGUMENT-USES-ONWARD,M-ARGUMENT-USES-OVERRIDES,M-TOUCH-ARGUMENT-USES,'
			+ 'M-TOUCH-ARGUMENT-LEAVES',
		'unit.query.MemberReachFactsTest#testAnArrayMemberOfASubclassUnderAnAncestorsAutoBuildIsAnsweredUnderTheTruth :: control :: '
			+ 'M-REACH-REWRITTEN-TRUTH,M-REACH-REWRITTEN-UNTRUE',
		'unit.query.MemberReachFactsTest#testAnEnvironmentReadRunsNoProjectCodeUnderTheTruth :: control :: '
			+ 'M-SHAPE-PURE-GETENV,M-REACH-RUN-QUIET',
		'unit.query.MemberReachFactsTest#testAnEscapeTheCompilerTypesCostsOnlyItsOwnFamily :: control :: M-FACTS-REACH-ESCAPE-TYPED',
		'unit.query.MemberReachFactsTest#testAnEscapedValueMayBeAnyOfItsSubtypesUnderTheTruth :: control :: M-ESCAPES-FACTS-SUBTYPES',
		'unit.query.MemberReachFactsTest#testAnExpressionBodiedReturnLandsAtItsFunctionsReturnType :: control :: '
			+ 'M-SITES-EXPR-RETURN-NO-LANDING',
		'unit.query.MemberReachFactsTest#testAnExpressionMacroAnInlinedMethodCallsLeavesItsCallerItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-EXPANSION,M-FACTS-TEXT-EXPANSION-SPLICED,M-FACTS-EXPANSION-NESTED',
		'unit.query.MemberReachFactsTest#testAnExpressionMacroAnInlinedSetterIsHandedIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-EXPANSION-SIBLING',
		'unit.query.MemberReachFactsTest#testAnExpressionMacroInAWhollyInlinedInitializerIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-EXPANSION-OUTER',
		'unit.query.MemberReachFactsTest#testAnExpressionMacroInAnInlinedCallBesideACapturedThisIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-SITE-HOLDS-OWN-CODE',
		'unit.query.MemberReachFactsTest#testAnExpressionMacroInAnInlinedCallsArgumentIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-EXPANSION-SITE',
		'unit.query.MemberReachFactsTest#testAnExpressionMacroTheTextCallsLeavesItsTypeItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-EXPANSION,M-FACTS-TEXT-EXPANSION-BODY,M-FACTS-EXPANSION-RECORDED,M-FACTS-MACRO-CALLEE',
		'unit.query.MemberReachFactsTest#testAnExtensionAnotherBuildBringsInIsKeptFromTheSyntax :: control :: '
			+ 'M-FACTS-REACH-SYNTAX-UNION,M-GRAPH-TRUTH-MUTE-ALWAYS',
		'unit.query.MemberReachFactsTest#testAnExtensionOnlyAListedBuildBringsInIsReadFromItsFacts :: control :: M-GRAPH-TRUTH-MUTE',
		'unit.query.MemberReachFactsTest#testAnExternHandedAnObjectCarryingTheMemberMayWriteItByNameUnderTheTruth :: control :: '
			+ 'M-EXTERN-BLIND-HANDED,M-EXTERN-BLIND-NAMES-NO-MEMBER,M-EXTERN-BLIND-DECLARED,M-EXTERN-BLIND-SYNTAX,M-EXTERN-BLIND-REPORT',
		'unit.query.MemberReachFactsTest#testAnExternReadsEveryCallOfItWithoutTheTruth :: control :: '
			+ 'M-EXTERN-EVERY-CALLER-SYNTAX,M-EXTERN-EVERY-CALL-SYNTAX',
		'unit.query.MemberReachFactsTest#testAnExternRunsOnlyWhatTheValuesItsCallersHandItLetItRunUnderTheTruth :: control :: '
			+ 'M-EXTERN-HANDED-FACTS,M-EXTERN-HANDED-RECEIVER,M-EXTERN-CALLERS,M-EXTERN-REVISIT,M-NATIVE-SITE-TAKEN-VALUES,'
			+ 'M-NATIVE-SITE-ARRAY-ELEMENTS',
		'unit.query.MemberReachFactsTest#testAnInitializerThatIsWhollyAnInlinedCallIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-INLINED-WHOLE',
		'unit.query.MemberReachFactsTest#testAnInitializerThatIsWhollyAnInlinedConstructorIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-INLINED-CONSTRUCTION',
		'unit.query.MemberReachFactsTest#testAnInlinedCallKeepsItsBodysSyntax :: control :: '
			+ 'M-FACTS-REACH-SPLICE,M-FACTS-TRUTH-SPLICE-ALWAYS',
		'unit.query.MemberReachFactsTest#testAnInlinedGenericBodyConvertsOnlyWhatEachCallHandsItUnderTheTruth :: control :: '
			+ 'M-REACH-SPLICE-ONLY,M-FACTS-INLINED-EDGE',
		'unit.query.MemberReachFactsTest#testAnInlinedLibraryBodyReadOnDemandStaysSplicedInUnderTheTruth :: control :: '
			+ 'M-REACH-SPLICE-EXTERNAL',
		'unit.query.MemberReachFactsTest#testAnInlinedMethodWhoseBodyIsAnInlinedCallOfConstantsIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-WALK-WRITTEN-CONSTANT',
		'unit.query.MemberReachFactsTest#testAnInstanceOfAClassExtendingAnExternEscapesUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-EXTENDS-EXTERN',
		'unit.query.MemberReachFactsTest#testAnInterfacePropertyReadThroughAnInlinedAbstractRunsItsImplementations :: control :: '
			+ 'M-GRAPH-FACTS-INTERFACE-PLACEHOLDER,M-GRAPH-VIRTUAL-OWN-ONLY,M-GRAPH-ABSTRACT-THIS-STORAGE,'
			+ 'M-REACH-OVERRIDES-INHERITED-UNLOADED',
		'unit.query.MemberReachFactsTest#testAnUnannotatedArrayMemberIsAnArrayUnderTheTruth :: control :: '
			+ 'M-REACH-TYPED-ARRAY-NEVER,M-REACH-TYPED-ARRAY-ANY',
		'unit.query.MemberReachFactsTest#testAnUntypedIndexAccessKeepsItsHazardUnderTheTruth :: control :: '
			+ 'M-FACTS-TRUTH-UNTYPED-ALL,M-FACTS-TRUTH-UNTYPED-SHAPE',
		'unit.query.MemberReachFactsTest#testCodeABuildMacroLeftAsItsTextIsAnsweredUnderTheTruth :: control :: '
			+ 'M-REACH-REWRITTEN-TRUTH,M-REACH-REWRITTEN-UNTRUE',
		'unit.query.MemberReachFactsTest#testCodeInAnInterpolatedStringPastAnEscapeIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-INTERPOLATION',
		'unit.query.MemberReachFactsTest#testCodeNoBuildCompilesHasNoAnswerUnderTheTruth :: control :: '
			+ 'M-REACH-DEAD-FILE-ENTRY,M-REACH-DEAD-FILE-LOCAL-ENTRY',
		'unit.query.MemberReachFactsTest#testCodeNoBuildCompilesRunsNothingUnderTheTruth :: control :: '
			+ 'M-REACH-DEAD-NODE-ENTERED,M-LIVE-FRAGMENTED',
		'unit.query.MemberReachFactsTest#testCodeReadByItsSyntaxConvertsAValueThatLeftTheTypeSystem :: control :: '
			+ 'M-REACH-SYNTAX-CONVERSION,M-SITES-LANDING-KEEPING-PLACE,M-SITES-LANDING-CLASS-PLACE,M-SITES-LANDING-TYPED-VALUE',
		'unit.query.MemberReachFactsTest#testCodeReadByItsSyntaxMayRunTheConversionsOfATypeTheIndexDeclaresNowhere :: control :: '
			+ 'M-REACH-ALWAYS-TEXTLESS,M-REACH-MENTIONS-TYPED',
		'unit.query.MemberReachFactsTest#testCodeReadThroughItsFactsRunsNoOperatorOverloadItNamesNoCallOfUnderTheTruth :: control :: '
			+ 'M-ADMIT-SYNTAX-READ-FIELD,M-REACH-UNREAD-NARROWED,M-FACTS-ABSTRACT-CTOR-NAME',
		'unit.query.MemberReachFactsTest#testCodeTheWalkDoesNotReadMayRunTheImplicitMembersOfATypeTheIndexDeclaresNowhere :: control :: '
			+ 'M-REACH-UNREAD-TEXTLESS',
		'unit.query.MemberReachFactsTest#testEscapesReadOffEveryBuildsFactsLetAThrownValueRunOnlyItsOwnToString :: control :: '
			+ 'M-ESCAPES-TRUTH-FACTS,M-ESCAPES-FACTS-REFLECTION-INLINED,M-FACTS-ALIAS-TYPEDEF,M-FACTS-IMPLICIT-EXTERN,'
			+ 'M-REACH-TEXT-EXTERN-INLINE',
		'unit.query.MemberReachFactsTest#testFactsThatAreNotTheTruthNarrowNothingCodeTheWalkNeverEntersRuns :: control :: '
			+ 'M-ADMIT-SYNTAX-READ-UNTRUE',
		'unit.query.MemberReachFactsTest#testJoiningAFieldOfStringsConvertsNothingOnHxcppUnderTheTruth :: control :: '
			+ 'M-REACH-HANDED-CONVERTED',
		'unit.query.MemberReachFactsTest#testJoiningAnArrayRunsItsElementsToStringAloneUnderTheTruth :: control :: '
			+ 'M-REACH-ARRAY-OWN-HANDS',
		'unit.query.MemberReachFactsTest#testLibraryCodeNotReadYetMayRunAnyOperatorOverloadUnderTheTruth :: control :: '
			+ 'M-ADMIT-SYNTAX-READ-UNSEEN,M-REACH-UNREAD-RECHECK,M-REACH-TYPED-IMPLICIT-TEXT',
		'unit.query.MemberReachFactsTest#testLibraryCodeNotReadYetMayRunTheOperatorOverloadOfATypeTheIndexDeclaresNowhere :: control :: '
			+ 'M-REACH-UNREAD-READ-FAMILIES,M-REACH-TYPED-IMPLICIT-TEXT',
		'unit.query.MemberReachFactsTest#testLibraryTargetCodeIsReadLikeTheProjectsUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-NATIVE-LOCALS',
		'unit.query.MemberReachFactsTest#testNoReadOfATypeTheIndexDoesNotHoldIsOneOfItsNamesakeUnderTheTruth :: control :: '
			+ 'M-FACTS-UNHELD-SUPER,M-FACTS-UNHELD-NEW,M-FACTS-UNHELD-VALUE,M-FACTS-UNHELD-OVERRIDE,M-REACH-UNHELD-IMPLICIT,'
			+ 'M-REACH-UNHELD-REFLECTED,M-FACTS-UNHELD-HOMES,M-FACTS-UNHELD-NAMED',
		'unit.query.MemberReachFactsTest#testOnlyTheProjectTypeAFactCallsTouchesUnderTheTruth :: control :: M-REACH-QUALIFIED-NONE,'
			+ 'M-REACH-QUALIFIED-SIMPLE-TOUCH,M-TOUCH-SCAN-NODE-UNRECORDED,M-FACTS-QUALIFIED-ANY-DECLARATION,M-REACH-QUALIFIED-ESCAPE',
		'unit.query.MemberReachFactsTest#testProjectTargetCodeKeepsThisBoundUnderTheTruth :: control :: M-METHODS-NATIVE-REFUSED',
		'unit.query.MemberReachFactsTest#testTargetCodeAMetadataPastesIsReadLikeACallsUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-CODE-META,M-FACTS-CODE-META,M-ESCAPES-FACTS-NATIVE-COMPUTED',
		'unit.query.MemberReachFactsTest#testTargetCodeHandedAValueLetsItEscapeUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-NATIVE-LOCALS,M-FACTS-NATIVE-CODE',
		'unit.query.MemberReachFactsTest#testTargetCodeHandedOnlyValuesReachesNoObjectUnderTheTruth :: control :: '
			+ 'M-NATIVE-SITE-CORE-TYPE,M-UNCHECKED-TARGET,M-UNCHECKED-BOXED,M-NATIVE-SITE-COMPUTED',
		'unit.query.MemberReachFactsTest#testTargetCodeNamingAClassRunsWhatTheClassHoldsUnderTheTruth :: control :: '
			+ 'M-NATIVE-CLASSES-NAMED',
		'unit.query.MemberReachFactsTest#testTargetCodeNamingAStaticLetsWhatItHoldsEscapeUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-NATIVE-STATICS,M-ESCAPES-FACTS-NATIVE-OWN-STATICS,M-ESCAPES-FACTS-NATIVE-STATIC-CLASS',
		'unit.query.MemberReachFactsTest#testTargetCodeNamingNoValueLetsNothingEscapeUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-NATIVE-REFUSED',
		'unit.query.MemberReachFactsTest#testTargetCodeNamingThisLetsItsObjectEscapeUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-NATIVE-THIS,M-ESCAPES-FACTS-NATIVE-MEMBERS,M-ESCAPES-FACTS-NATIVE-THIS-ALWAYS',
		'unit.query.MemberReachFactsTest#testTargetCodeReachesTheMemberOnlyThroughWhatItIsHandedUnderTheTruth :: control :: '
			+ 'M-NATIVE-SITE-BLIND,M-NATIVE-SITE-NAMES,M-NATIVE-SITE-ESCAPED,M-NATIVE-SITE-VALUES,M-FACTS-NATIVE-HANDED,'
			+ 'M-FACTS-NATIVE-CHAIN,M-ESCAPES-FACTS-NATIVE-HANDED,M-NATIVE-LITERAL-CODE,M-NATIVE-LITERAL-CHAIN',
		'unit.query.MemberReachFactsTest#testTheArraysOwnMethodReachesItsElementsOnlyByConvertingThemUnderTheTruth :: control :: '
			+ 'M-REACH-ARRAY-VALUES',
		'unit.query.MemberReachFactsTest#testTheCompilerResolvesACallTheSyntaxCannot :: control :: M-FACTS-REACH-EDGES',
		'unit.query.MemberReachFactsTest#testTheCompilersHierarchyReachesAnOverride :: control :: M-FACTS-REACH-OVERRIDES',
		'unit.query.MemberReachFactsTest#testTheFactsAreTheTruthOnlyUnderTheWholeListOfTheirBuilds :: control :: '
			+ 'M-FACTS-TRUTH-WIRED,M-FACTS-SOURCE-UNLISTED',
		'unit.query.MemberReachFactsTest#testTheFactsNameTheNativeCallsUnderTheTruth :: control :: '
			+ 'M-FACTS-TRUTH-NATIVES,M-FACTS-TRUTH-NATIVE-CALLS-KEPT,M-FACTS-TRUTH-NATIVE-METAS-DROPPED',
		'unit.query.MemberReachFactsTest#testTheFunctionAPartialApplicationMakesIsItsTextUnderTheTruth :: control :: '
			+ 'M-FACTS-TEXT-READ-AT-VALUE,M-FACTS-TEXT-BINDING',
		'unit.query.MemberReachFactsTest#testTheIndexSpellsEachDeclarationAsTheBuildsTypeIt :: control :: '
			+ 'M-INDEX-GUARDED-PRIVATE,M-INDEX-MODULE-PLATFORM,M-FACTS-IMPLEMENTED-TYPED',
		'unit.query.MemberReachFactsTest#testTheInitializersOfATypeOfASharedNameAreEachTypedTypesUnderTheTruth :: control :: '
			+ 'M-REACH-OWN-TYPES-INIT-NONE,M-FACTS-INIT-OWNERS-SOLE,M-FACTS-QUALIFY-SITELESS',
		'unit.query.MemberReachFactsTest#testTheOneDeclarationOfANameAsksItsOwnBuildMacroUnderTheTruth :: control :: '
			+ 'M-FACTS-PROVENANCE-SIMPLE,M-FACTS-PROVENANCE-UNTRUE,M-FACTS-TEXT-PROVENANCE-SIMPLE',
		'unit.query.MemberReachFactsTest#testTheOwnerTheFactsPinAtTheLoopIsOneOfTwoTypesUnderOneNameUnderTheTruth :: control :: '
			+ 'M-REACH-PINNED-NONE,M-FACTS-PINNED-UNTRUE,M-REACH-ENTRY-OWN-NONE,M-REACH-PINNED-REWRITTEN-SIMPLE',
		'unit.query.MemberReachFactsTest#testThePushesOfAComprehensionAreItsTextUnderTheTruth :: control :: M-FACTS-TEXT-COMPREHENSION',
		'unit.query.MemberReachFactsTest#testTheReceiverOfAFieldReachedByNameEscapesUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-DYNAMIC-RECEIVER',
		'unit.query.MemberReachFactsTest#testTheReceiverOfAMethodReadAsAValueEscapesUnderTheTruth :: control :: M-ESCAPES-FACTS-CLOSURE',
		'unit.query.MemberReachFactsTest#testTheSecondDeclarationOfAFoldedMemberIsReadByItsText :: control :: M-REACH-FOLDED-BODIES',
		'unit.query.MemberReachFactsTest#testTheSubtypesOfTheOneDeclarationOfANameAreItsOwnUnderTheTruth :: control :: '
			+ 'M-FACTS-SUBTYPES-PROVENANCE',
		'unit.query.MemberReachFactsTest#testTheTruthNeedsTheFactsToNameExactlyTheListedBuilds :: control :: '
			+ 'M-FACTS-TRUTH-UNLISTED,M-FACTS-TRUTH-COUNT,M-FACTS-TRUTH-NAMES,M-FACTS-TRUTH-ORDER',
		'unit.query.MemberReachFactsTest#testThisOfAConstructorIsAnyEscapedInstanceOnceACallMayRebindUnderTheTruth :: control :: '
			+ 'M-METHODS-REBINDS,M-METHODS-METHOD-ONLY',
		'unit.query.MemberReachFactsTest#testThisOfAMethodACallMayRebindIsAnyEscapedInstanceUnderTheTruth :: control :: '
			+ 'M-METHODS-SELF-BOUND,M-METHODS-CLOSURE-READ,M-FACTS-REFL-HOLDER,M-METHODS-RECEIVER-BOUND',
		'unit.query.MemberReachFactsTest#testTwoTypesUnderOneNameStayAmbiguousUnderTheTruth :: control :: '
			+ 'M-REACH-AMBIGUOUS-SOLE-ANY,M-FACTS-SOLE-TYPED-ONLY,M-FACTS-SOLE-STANDS-ANY',
		'unit.query.MemberReachFactsTest#testUnderTheTruthASpliceElsewhereInTheFunctionIsNoneOfTheRegions :: control :: '
			+ 'M-REACH-SPLICED-SITES,M-GRAPH-FACTS-SPLICE-TAG,M-GRAPH-FACTS-INLINED-SITE,M-FACTS-SPLICE-SITE,'
			+ 'M-FACTS-SPLICE-SITE-INNERMOST,M-FACTS-SPLICE-BODY',
		'unit.query.MemberReachFactsTest#testUnderTheTruthASplicedPushOnAFreshLocalOfItsMethodChangesNothingShared :: control :: '
			+ 'M-REACH-SPLICED-BENIGN,M-REACH-SPLICED-CULPRIT,M-REACH-WHERE-WRITTEN-RANGE,M-GRAPH-FACTS-SPLICE-TAG',
		'unit.query.MemberReachFactsTest#testUnderTheTruthASplicedReflectiveBodyThatReachesNoMemberLeavesItsFunctionReadable :: control :: '
			+ 'M-FACTS-SPLICED-REFLECTION-READ,M-FACTS-SPLICED-REFLECTION-FROM,M-FACTS-SPLICED-REFLECTION-MEMBERLESS',
		'unit.query.MemberReachFactsTest#testUnderTheTruthASplicedStringConversionIsTheRegions :: control :: '
			+ 'M-FACTS-SPLICED-WITHIN-UNPLACED,M-FACTS-TRUTH-SITES-SPLICED,M-FACTS-SPLICED-WITHIN',
		'unit.query.MemberReachFactsTest#testUnderTheTruthAnEdgeSplicedFromAnotherFileIsNoSiteOfItsCaller :: control :: '
			+ 'M-GRAPH-FACTS-SPLICED-SITE',
		'unit.query.MemberReachFactsTest#testUnderTheTruthAnInlineConversionIsItsEdgeAlone :: control :: '
			+ 'M-FACTS-TRUTH-SPLICE,M-FACTS-SPLICED-WITHIN,M-FACTS-TRUTH-SITES-SPLICED',
		'unit.query.MemberReachFactsTest#testUnderTheTruthAnInlineConversionThatChangesTheMemberIsReached :: control :: '
			+ 'M-REACH-TRUTH-SPLICED-SEEDS,M-GRAPH-FACTS-SPLICED-SITE',
		'unit.query.MemberReachFactsTest#testUnderTheTruthAnInlinedCallIsReachedThroughItsEdge :: control :: '
			+ 'M-REACH-TRUTH-SPLICED-SEEDS,M-GRAPH-FACTS-SPLICED-SITE',
		'unit.query.MemberReachFactsTest#testUnderTheTruthAnInlinedReflectiveCallIsADynamicName :: control :: '
			+ 'M-FACTS-TRUTH-REFLECTION-INLINED,M-FACTS-SPLICED-REFLECTION-NAMED',
		'unit.query.MemberReachFactsTest#testUnderTheTruthUntypedCodeBesideAnInlinedCallIsReadThroughTheFacts :: control :: '
			+ 'M-FACTS-TRUTH-SPLICE,M-FACTS-TRUTH-HAZARDS-SPLICED,M-FACTS-SPLICED-WITHIN',
		'unit.query.MemberReachFactsTest#testUnderTheTruthWhatAPureLibraryCallSplicedInIsNoneOfTheRegions :: control :: '
			+ 'M-FACTS-SPLICE-HARMLESS,M-GRAPH-FACTS-SPLICE-HARMLESS,M-FACTS-SPLICE-SITE,M-FACTS-SPLICE-BODY',
		'unit.query.MemberReachFactsTest#testUnderTheWholeListTheCallOfALocalInlineFunctionKeepsItsEdge :: control :: '
			+ 'M-GRAPH-TRUTH-MUTE-UNTYPED',
		'unit.query.MemberReachFactsTest#testUnderTheWholeListTheSyntaxsEdgeAtASiteTheFactsTypeIsDropped :: control :: M-GRAPH-TRUTH-MUTE',
		'unit.query.MemberReachFactsTest#testUntypedCodeTheFactsRecordIsReadThroughThemUnderTheTruth :: control :: '
			+ 'M-FACTS-TRUTH-HAZARDS,M-FACTS-TRUTH-HAZARDS-UNLISTED,M-FACTS-TRUTH-UNTYPED-KEPT',
		'unit.query.MemberReachFactsTest#testWhatAnEscapedValueHoldsEscapesWithItUnderTheTruth :: control :: '
			+ 'M-ESCAPES-FACTS-FIELDS,M-ESCAPES-FACTS-ENUM,M-ESCAPES-FACTS-STRUCTURE,M-ESCAPES-FACTS-PLACE-ARGS,M-ESCAPES-FACTS-TYPE-ARGS',
		'unit.query.MemberReachFactsTest#testWhatAnIteratorReturnsIsNotIteratedInTurnUnderTheTruth :: control :: M-REACH-ITERABLE-RETURNS',
		'unit.query.MemberReachTest#testAClassNamedToTheClassValueProducerMayBeInstantiatedUntyped :: control :: M-ESCAPE-NAMED-CLASS',
		'unit.query.MemberReachTest#testAClasspathTheIndexDoesNotHoldMayDeclareAnOverrideOrASubtype :: control :: '
			+ 'M-REACH-CLASSPATH-DISPATCH,M-CARRY-CLASSPATH',
		'unit.query.MemberReachTest#testAConstructedReceiverIsItsOwnType :: control :: M-TS-NEW-RECEIVER',
		'unit.query.MemberReachTest#testAConversionOfATypedOperandRunsOnlyItsTypesMethod :: control :: M-REACH-TYPED-SITE',
		'unit.query.MemberReachTest#testAConversionReadsEveryCopyOfOneLibraryType :: control :: M-REACH-HOMES-RECORDED,M-REACH-LIBRARY-HOMES,M-REACH-SHARED-ONE-TYPE',
		'unit.query.MemberReachTest#testACopyWhoseCodeTheNodeDoesNotHoldStaysShared :: control :: M-REACH-ONE-TYPE-FOLDED,M-REACH-ONE-TYPE-EXTERN',
		'unit.query.MemberReachTest#testAFieldInitializerRunsWhatItHoldsThoughItCallsNothing :: control :: '
			+ 'M-GRAPH-EAGER-INIT,M-REACH-INIT-BRANCHES',
		'unit.query.MemberReachTest#testALibraryReadOfTheMemberByItsNameIsATouch :: control :: M-REACH-LIB-ACCESS',
		'unit.query.MemberReachTest#testAMemberDeclaredInEachBranchIsWhatEveryDeclarationSays :: control :: '
			+ 'M-GRAPH-JOINED-MEMBER,M-REACH-SHARED-INIT-BRANCHES,M-GRAPH-FOLDED-DYNAMIC',
		'unit.query.MemberReachTest#testANameAnImportDoesNotBindToTheMemberIsNoTouch :: control :: '
			+ 'M-REACH-IMPORT-ALIAS-OTHER-TYPE,M-REACH-IMPORT-ALIAS-LOCAL,M-REACH-IMPORT-ALIAS-MEMBER',
		'unit.query.MemberReachTest#testAPositionTypedOnlyOnTheOutsideHoldsAnything :: control :: '
			+ 'M-CARRY-TYPED-ARGS,M-CARRY-TYPED-ARITY,M-ESCAPE-UNWRITTEN-ARGS',
		'unit.query.MemberReachTest#testARawRegionSpellingOnlyTheAliasIsABlindSpot :: control :: M-REACH-IMPORT-ALIAS-OPAQUE',
		'unit.query.MemberReachTest#testAReadNoReceiverTypeDeclaresReachesWhatItMayBe :: control :: '
			+ 'M-REACH-EXTENSION-READ,M-REACH-GENERATED-READ,M-REACH-FILE-IMPORTS,M-GRAPH-READ-DECLARED',
		'unit.query.MemberReachTest#testAStaticImportedUnderAnotherNameIsTouchedThroughTheAlias :: control :: '
			+ 'M-REACH-IMPORT-ALIAS,M-REACH-IMPORT-ALIAS-SELF',
		'unit.query.MemberReachTest#testAStaticImportedUnderItsOwnNameIsTouched :: guard :: ',
		'unit.query.MemberReachTest#testAStructureFunctionFieldBringsOnlyWhatItsTextSpells :: control :: M-REACH-INFERRED-ANON-METHOD',
		'unit.query.MemberReachTest#testATypeReExportedUnderItsOwnNameStillHasOneDeclarationSite :: control :: M-REACH-SITE-SELF-ALIAS',
		'unit.query.MemberReachTest#testAValueOfAnInterfaceOnlyASubtypeSharesCarriesTheMember :: control :: M-CARRY-SUBTYPE-MEET',
		'unit.query.MemberReachTest#testAVersionComparisonIsDecidedByTheValueEveryBuildGivesIt :: control :: M-REACH-LIVE-VALUES',
		'unit.query.MemberReachTest#testAliasWrittenInTheRegionItselfIsRefused :: control :: M-REACH-ESCAPE-GATE',
		'unit.query.MemberReachTest#testAnAbstractsMemberRunsOnlyWhereItsTypeIsInReach :: control :: '
			+ 'M-REACH-ABSTRACT-VISIBLE,M-REACH-MEMBER-READ,M-REACH-INFERRED-MEMBER,M-GRAPH-IMPLICIT-META',
		'unit.query.MemberReachTest#testAnAccessThroughAnInterfaceTheOwnerImplementsIsATouch :: control :: '
			+ 'M-REACH-RECEIVER-OWNER,M-CARRY-SUBTYPE-MEET',
		'unit.query.MemberReachTest#testAnAnswerDoesNotDependOnTheQuestionsBeforeIt :: control :: M-REACH-QUESTION-ENTERED',
		'unit.query.MemberReachTest#testAnEditToAFileOfANodeFoldedAcrossFilesRebuildsTheGraph :: control :: M-REACH-REFRESH-FOLDED',
		'unit.query.MemberReachTest#testAnImportedFunctionReadAsAValueIsAdmittedAtAValueCall :: control :: '
			+ 'M-CALLGRAPH-ALIAS-VALUE,M-CALLGRAPH-IMPORTED-VALUE',
		'unit.query.MemberReachTest#testAnInstanceThatLeftTheTypeSystemMayBeAnyType :: control :: '
			+ 'M-CARRY-ESCAPES,M-ESCAPE-STORE,M-ESCAPE-CAST,M-ESCAPE-DECL,M-ESCAPE-PARAM,M-ESCAPE-RETURN,M-ESCAPE-LAMBDA,M-ESCAPE-THROW,'
			+ 'M-ESCAPE-METHOD-VALUE,M-ESCAPE-HELD,M-ESCAPE-LIBRARY-SUPER,M-ESCAPE-NATIVE,M-ESCAPE-ANY',
		'unit.query.MemberReachTest#testAssignmentUsedAsAValueSharesWhatItStores :: control :: M-REACH-ASSIGNMENT-VALUE-ALIAS',
		'unit.query.MemberReachTest#testBodylessLibraryCallAdmitsImplicitlyCalledMethods :: control :: '
			+ 'M-REACH-EXTERN-HANDS,M-EXTERN-BLIND-SYNTAX-LITERAL',
		'unit.query.MemberReachTest#testBranchNoConfiguredBuildCompilesIsNotWalked :: control :: M-REACH-LIVE-HAZARDS,M-REACH-LIVE-EDGES',
		'unit.query.MemberReachTest#testBuildMacroOnTheOwnerIsUnknown :: control :: M-REACH-BUILD-MACRO',
		'unit.query.MemberReachTest#testCallbackArrayMethodRunsTheFunctionItIsHanded :: control :: '
			+ 'M-REACH-EXTERN-BODYLESS,M-REACH-CALLS-ARGUMENT',
		'unit.query.MemberReachTest#testCalleeChangingOnlyAFreshLocalOfItsOwnIsProven :: control :: M-REACH-CALLEE-BENIGN-EDGE',
		'unit.query.MemberReachTest#testCalleeDispatchOnALibraryTypeReachesItsLibraryOverrides :: control :: M-REACH-CALLEE-OVERRIDES',
		'unit.query.MemberReachTest#testCalleeWhoseBodyIsNotItsSourceIsRefused :: control :: '
			+ 'M-REACH-CALLEE-REWRITTEN,M-REACH-CALLEE-AMBIGUOUS',
		'unit.query.MemberReachTest#testCallsEntryStartsAtTheSitesOnly :: control :: M-REACH-CALLS-ENTRY',
		'unit.query.MemberReachTest#testCompilerFactsSendEveryUnprovedQuestionToTheBuilds :: control :: '
			+ 'M-REACH-ESCALATE-TRUTH-NEVER,M-REACH-ESCALATE-TRUTH-WITHOUT-FACTS,M-REACH-ESCALATE-TRUTH-DROPPED',
		'unit.query.MemberReachTest#testCompoundAssignmentRunsTheBinaryOperatorOverload :: control :: '
			+ 'M-REACH-COMPOUND-OPERATOR,M-REACH-UNDECLARED-PRIMITIVE',
		'unit.query.MemberReachTest#testConstructNobodyClassifiedIsUnknown :: control :: M-REACH-UNMODELLED',
		'unit.query.MemberReachTest#testConstructingAnotherInstanceIsNotATouch :: control :: M-REACH-FRESH-OBJECT',
		'unit.query.MemberReachTest#testConstructorOfALibrarySubclassIsNotADispatchTarget :: control :: M-REACH-CTOR-NOT-DISPATCHED',
		'unit.query.MemberReachTest#testConstructorRunsTheFieldInitializers :: control :: M-GRAPH-INIT-WIRING',
		'unit.query.MemberReachTest#testCopyOfAnArrayIsFresh :: control :: M-REACH-FRESH-METHOD',
		'unit.query.MemberReachTest#testDynamicFunctionACalleeRunsIsRefused :: guard :: ',
		'unit.query.MemberReachTest#testDynamicReceiverAdmitsBySameName :: control :: M-REACH-NAME-CHANNEL',
		'unit.query.MemberReachTest#testEscapeLaterInAnEnclosingLoopPrecedesTheNextRun :: control :: M-REACH-RERUN-END',
		'unit.query.MemberReachTest#testEveryDeclarationOfAMemberInEachBranchIsRead :: control :: '
			+ 'M-REACH-FOLDED-BODIES,M-GRAPH-FOLDED-DECLARATIONS',
		'unit.query.MemberReachTest#testEveryEscapeRuleLetsItsSoundTwinThrough :: control :: '
			+ 'M-ESCAPE-P-STORE,M-ESCAPE-P-CAST,M-ESCAPE-P-THROW,M-ESCAPE-P-DECL,M-ESCAPE-P-PARAM,M-ESCAPE-P-RETURN,M-ESCAPE-P-LAMBDA,'
			+ 'M-ESCAPE-P-METHOD-VALUE,M-ESCAPE-P-HELD,M-ESCAPE-P-LIBRARY-SUPER,M-ESCAPE-P-NATIVE,M-ESCAPE-P-TYPED-ARGS,'
			+ 'M-ESCAPE-DECLARED-SOURCE,M-ESCAPE-LOCAL-INIT,M-ESCAPE-PRIMITIVE-PARAM,M-ESCAPE-ASSIGN-VALUE,M-ESCAPE-IF-VALUE,'
			+ 'M-ESCAPE-BLOCK-VALUE,M-ESCAPE-MACRO-MEMBER,M-ESCAPE-MACRO-HAZARD,M-ESCAPE-REIFICATION,M-ESCAPE-THROW,M-ESCAPE-DECL,'
			+ 'M-ESCAPE-PARAM,M-ESCAPE-LAMBDA,M-ESCAPE-STORE,M-ESCAPE-CAST,M-ESCAPE-METHOD-VALUE,M-ESCAPE-HELD,M-ESCAPE-LIBRARY-SUPER,'
			+ 'M-ESCAPE-NATIVE,M-ESCAPE-NEW-TYPE',
		'unit.query.MemberReachTest#testExplainNamesThePath :: control :: M-REACH-EXPLAIN-PATH',
		'unit.query.MemberReachTest#testExternClosedOverInertValuesAdmitsNoFunctionValue :: control :: M-REACH-EXTERN-INERT',
		'unit.query.MemberReachTest#testExternHandedAnEnumValueRunsWhatItsArgumentsHoldByName :: control :: '
			+ 'M-REACH-EXTERN-ENUM-ARGS,M-REACH-EXTERN-ENUM-CTOR',
		'unit.query.MemberReachTest#testExternHandedAnObjectRunsItsMembersByName :: control :: M-REACH-EXTERN-OBJECT',
		'unit.query.MemberReachTest#testExternHandedAnObjectRunsWhatItsFieldsHoldByName :: control :: M-REACH-EXTERN-NESTED',
		'unit.query.MemberReachTest#testExternHandedOnlyInertValuesRunsNoProgramCode :: control :: M-REACH-IMPLICIT-INSTANCE',
		'unit.query.MemberReachTest#testExternMethodRunsItsReceiversMembersByName :: control :: M-REACH-EXTERN-RECEIVER',
		'unit.query.MemberReachTest#testExternMethodRunsTheFunctionItIsHanded :: control :: M-REACH-EXTERN-BODYLESS,M-REACH-EXTERN-CLOSED',
		'unit.query.MemberReachTest#testFieldOfAnAnonymousStructureIsNotAMethodRead :: control :: M-GRAPH-STORED-FIELD',
		'unit.query.MemberReachTest#testFieldWithoutTheWholeProjectIsUnknown :: control :: M-REACH-OUT-OF-SCOPE',
		'unit.query.MemberReachTest#testFreshMethodMustBeTheReceiverTypesOwn :: control :: M-REACH-FRESH-TYPED',
		'unit.query.MemberReachTest#testFreshUnsharedLocalIsProvenWhateverTheBodyCalls :: control :: M-REACH-LOCAL-FRESH',
		'unit.query.MemberReachTest#testFreshWriteEndingAStatementBodyKeepsTheLocalUnshared :: control :: '
			+ 'M-REACH-DISCARDED-BODY,M-REACH-DISCARDED-STATEMENT-BRANCH',
		'unit.query.MemberReachTest#testFreshWriteEndingAValueBlockSharesWhatItStores :: control :: M-REACH-LAST-STATEMENT-VALUE',
		'unit.query.MemberReachTest#testFunctionValueCallAdmitsAValueUsedMutator :: control :: M-REACH-VALUE-CHANNEL',
		'unit.query.MemberReachTest#testFunctionValueCallWithNoValueUsedMutatorIsProven :: control :: M-REACH-WALK-UNKNOWN',
		'unit.query.MemberReachTest#testGetterReadInTheRegionIsAnEntry :: control :: M-GRAPH-GETTER-EDGE',
		'unit.query.MemberReachTest#testHazardInTheRegionItselfIsUnknown :: control :: M-REACH-ENTRY-HAZARDS',
		'unit.query.MemberReachTest#testImplicitFunctionCallingACallbackMethodMayChangeArrays :: control :: M-REACH-CALLBACK-PURE',
		'unit.query.MemberReachTest#testImplicitFunctionCallingAnExternMayChangeArrays :: control :: '
			+ 'M-REACH-IMPLICIT-BODYLESS,M-REACH-FORWARDING-OP',
		'unit.query.MemberReachTest#testImplicitMembersOnlyOfTypesInPlayCount :: control :: '
			+ 'M-REACH-IMPLICIT-WRITTEN,M-REACH-EXTERN-IMPLICIT-QUIET',
		'unit.query.MemberReachTest#testImplicitMethodAnywhereMayRunAFunctionValue :: control :: '
			+ 'M-REACH-IMPLICIT-PLACEHOLDER,M-REACH-CLOSURE-CHANNELS,M-REACH-CLOSURE-LIBRARY',
		'unit.query.MemberReachTest#testImplicitOperatorIsRunFromArithmetic :: control :: M-GRAPH-OPERATOR-KIND,M-REACH-IMPLICIT-ADMIT',
		'unit.query.MemberReachTest#testImplicitlyCalledMethodsAreRunFromStringsAndIteration :: control :: M-REACH-IMPLICIT-RUNS-CODE',
		'unit.query.MemberReachTest#testIndexOperatorOverloadRunsFromAnIndexAccess :: control :: M-REACH-INDEX-OPERATOR',
		'unit.query.MemberReachTest#testInterfaceCallDispatchesToTheImplementationOnly :: control :: M-REACH-INTERFACE-DISPATCH',
		'unit.query.MemberReachTest#testIterationRunsOnlyFromALoopOverAValue :: control :: M-REACH-FAMILY-MATCH',
		'unit.query.MemberReachTest#testJoinConvertsTheElementsToStrings :: control :: M-REACH-JOIN-CONVERTS,M-REACH-JOIN-CULPRIT',
		'unit.query.MemberReachTest#testLibraryBodyIsReadOnDemand :: control :: M-REACH-LIBRARY-GROWTH',
		'unit.query.MemberReachTest#testLibraryBudgetIsPerQuestion :: control :: M-REACH-QUESTION-BUDGET',
		'unit.query.MemberReachTest#testLibraryCallHandedAnObjectIsNotPure :: control :: M-REACH-PURE-PARAMS',
		'unit.query.MemberReachTest#testLibraryCodeTheWalkCannotReadIsNamed :: control :: M-REACH-UNREAD-NAMED',
		'unit.query.MemberReachTest#testLibraryFileNoConfiguredBuildParsesIsNotInPlay :: control :: '
			+ 'M-REACH-COMPILED-ONLY,M-REACH-ESCALATE-NEVER,M-REACH-ESCALATE-ALWAYS,M-REACH-ESCALATE-INCOMPLETE',
		'unit.query.MemberReachTest#testLibraryGrowthPastTheCapIsUnknown :: control :: M-REACH-LIBRARY-BUDGET',
		'unit.query.MemberReachTest#testLibraryInstanceMadeOutOfSightRunsItsMembers :: control :: '
			+ 'M-REACH-CONSTRUCTIBLE,M-REACH-INDEX-IMPLICIT',
		'unit.query.MemberReachTest#testLiteralTypedAsAConstructedClassRunsItsConstructor :: control :: M-REACH-IMPLICIT-CONSTRUCTION',
		'unit.query.MemberReachTest#testLocalCapturedByAClosureIsAnEscape :: control :: M-REACH-LOCAL-CAPTURE',
		'unit.query.MemberReachTest#testLocalGivenASharedValueByAnyWriteIsNotFresh :: control :: M-REACH-COMPOUND-WRITE-ALIAS',
		'unit.query.MemberReachTest#testLocalHandedOutIsAnEscape :: control :: M-REACH-LOCAL-ESCAPE',
		'unit.query.MemberReachTest#testMemoIsDroppedWhenAnyProjectFileChanged :: control :: '
			+ 'M-REACH-MEMO-EVERY-SOURCE,M-REACH-INCREMENTAL-PURGE',
		'unit.query.MemberReachTest#testMemoIsRebuiltWhenAMethodBecomesDynamic :: control :: M-REACH-MEMO-DYNAMIC',
		'unit.query.MemberReachTest#testMethodReadOffAnUntypedReceiverIsAdmitted :: control :: M-REACH-DYNAMIC-VALUE',
		'unit.query.MemberReachTest#testMutatingMethodIsATouchAndAReaderIsNot :: control :: M-REACH-METHOD-TOUCH',
		'unit.query.MemberReachTest#testNameTheEnclosingTypeDoesNotDeclareIsUnknown :: control :: M-REACH-NOT-A-MEMBER',
		'unit.query.MemberReachTest#testNativeCodeIsUnknown :: control :: M-REACH-NATIVE',
		'unit.query.MemberReachTest#testOnlyTheBuildsVouchForTheClasspath :: control :: M-REACH-BASE-CLASSPATH,M-REACH-TYPES-HELD',
		'unit.query.MemberReachTest#testParameterIsProvenOnlyWhenTheRegionRunsNothing :: control :: M-REACH-PARAM',
		'unit.query.MemberReachTest#testParameterRegionCallingACallbackMethodIsRefused :: control :: '
			+ 'M-REACH-BENIGN-CALLBACK,M-REACH-CALLS-ARGUMENT',
		'unit.query.MemberReachTest#testParameterRegionCallingOnlyArrayReadersIsProven :: control :: M-REACH-BENIGN-CALL',
		'unit.query.MemberReachTest#testParameterRegionCallingProjectCodeDependsOnWhatItChanges :: control :: '
			+ 'M-REACH-CALLEE-WALK,M-REACH-CALLEE-REFUSED',
		'unit.query.MemberReachTest#testParameterRegionHandingOnAFunctionValueIsRefused :: control :: M-REACH-REGION-REF',
		'unit.query.MemberReachTest#testParameterRegionOfArithmeticDependsOnWhatImplicitFunctionsChange :: control :: '
			+ 'M-REACH-IMPLICIT-ARRAY-CHANGE,M-REACH-ARRAY-CHANGE-SITE',
		'unit.query.MemberReachTest#testParameterRegionWritingAStringBufferIsProven :: control :: M-REACH-STRINGBUF-PURE',
		'unit.query.MemberReachTest#testParameterRegionWritingAnyOtherArrayIsRefused :: control :: M-REACH-REGION-ARRAY-CHANGE',
		'unit.query.MemberReachTest#testPropertyMemberIsUnknown :: control :: M-REACH-PROPERTY',
		'unit.query.MemberReachTest#testPureCalleeIsProven :: control :: M-REACH-WALK-UNKNOWN',
		'unit.query.MemberReachTest#testReflectionByComputedNameIsUnknown :: control :: M-REACH-REFLECT-COMPUTED',
		'unit.query.MemberReachTest#testReflectionByLiteralNameIsATouch :: control :: M-REACH-REFLECT-LITERAL',
		'unit.query.MemberReachTest#testReflectivePropertyWriteRunsTheSetter :: control :: M-REACH-REFLECT-ACCESSOR',
		'unit.query.MemberReachTest#testReflectiveReadOfTheMemberInLibraryCodeIsATouch :: control :: '
			+ 'M-REACH-LIB-REFLECT-TOUCH,M-REACH-LIB-REFLECT-UNSURE,M-REACH-LIB-REFLECT-UNRELATED',
		'unit.query.MemberReachTest#testRunWithAnUnmatchedRootDoesNotKnowTheProject :: control :: M-HOST-ROOTS-ALL',
		'unit.query.MemberReachTest#testSameNamedLocalIsNotATouch :: control :: M-REACH-LOCAL-SHADOW',
		'unit.query.MemberReachTest#testSameNamedMemberOfAnotherTypeIsNotATouch :: control :: M-REACH-RECEIVER-OWNER',
		'unit.query.MemberReachTest#testSetterWriteInTheRegionIsAnEntry :: control :: M-GRAPH-SETTER-EDGE',
		'unit.query.MemberReachTest#testSharedInitializerIsAnEscape :: control :: M-REACH-SHARED-INITIALIZER',
		'unit.query.MemberReachTest#testSharedParameterWithoutTheWholeProjectIsUnknown :: control :: M-REACH-LOCAL-SCOPE',
		'unit.query.MemberReachTest#testSlotWriteIsATouch :: control :: M-REACH-SLOT-WRITE',
		'unit.query.MemberReachTest#testSplitOfAStringAndAChainedResultAreFresh :: control :: '
			+ 'M-REACH-SPLIT-FRESH,M-REACH-FRESH-CHAIN,M-NOMINAL-LOCAL-INIT',
		'unit.query.MemberReachTest#testStoringASharedValueIsAnEscape :: control :: M-REACH-FRESH-ASSIGN',
		'unit.query.MemberReachTest#testTargetCodeCanNameAFreshLocal :: control :: M-REACH-LOCAL-HAZARDS',
		'unit.query.MemberReachTest#testTwoHopMutatorIsReached :: control :: M-REACH-TOUCHER-FOUND',
		'unit.query.MemberReachTest#testTypeSharingItsSimpleNameIsUnknown :: control :: M-REACH-AMBIGUOUS',
		'unit.query.MemberReachTest#testTypesOfTwoPackagesSharingANameStayShared :: control :: M-REACH-ONE-TYPE-PATHS',
		'unit.query.MemberReachTest#testUnannotatedFreshLocalArrayIsNotACulprit :: control :: M-REACH-UNTYPED-FRESH-LOCAL',
		'unit.query.MemberReachTest#testUnparsedLibraryFileSpellingTheDispatchIsUnknown :: control :: M-REACH-LIB-SKIP-OVERRIDE',
		'unit.query.MemberReachTest#testUnparsedProjectFileNamingTheMemberIsUnknown :: control :: M-REACH-SKIP-PARSE',
		'unit.query.MemberReachTest#testUnparsedProjectFileSpellingNothingIsStillUnknown :: control :: '
			+ 'M-REACH-SKIP-PARSE-ANY,M-REACH-SKIP-PARSE-LOCAL',
		'unit.query.MemberReachTest#testUntypedCodeIsUnknown :: control :: M-REACH-UNTYPED',
		'unit.query.MemberReachTest#testValueHandedOutIsAnEscape :: control :: M-REACH-ESCAPE-ARGUMENT',
		'unit.query.MemberReachTest#testWalkPastTheVisitCapIsUnknown :: control :: M-REACH-VISITED-BUDGET',
		'unit.query.MetaElementSpanSliceTest#testRemoveConditionalModifierRegionStillTakesTheMember :: control :: '
			+ 'M-META-ELEMENT-ANY-COND-REGION',
		'unit.query.MetaElementSpanSliceTest#testRemoveModifierStillTakesTheMemberDoc :: control :: M-CUT-DOC-KEPT-BY-ANY-PREFIX',
		'unit.query.MoveCanonicalOutputSliceTest#testMoveLeavesANonCanonicalSourceUnformatted :: control :: M-MOVE-CANONICALISE-ALWAYS',
		'unit.query.MoveElementsSliceTest#testALeadingDocTravelsWithTheSlice :: control :: M-MOVE-ELEMENTS-DOC-STAYS',
		'unit.query.MoveElementsSliceTest#testAOnePerLineSliceTakesItsLines :: control :: M-REMOVE-COMMA-LINE-KEPT',
		'unit.query.MoveElementsSliceTest#testARangeOutsideTheArrayIsRefused :: control :: M-MOVE-ELEMENTS-RANGE-UNCHECKED',
		'unit.query.MoveElementsSliceTest#testATargetPositionIsRefused :: control :: M-MOVE-ELEMENTS-TARGET-POSITION',
		'unit.query.MoveElementsSliceTest#testAnElementNamingAProjectTypeIsRefusedAcrossModules :: control :: M-MOVE-ELEMENTS-UNSEEN-TYPE',
		'unit.query.MoveElementsSliceTest#testAnElementReadingANameIsRefused :: control :: M-MOVE-ELEMENTS-READS-UNCHECKED',
		'unit.query.MoveElementsSliceTest#testOneArrayIsRefused :: control :: M-MOVE-ELEMENTS-NESTS-UNCHECKED',
		'unit.query.MoveElementsSliceTest#testVerifyCatchesASourceThatKeptTheSlice :: control :: M-MOVE-ELEMENTS-SOURCE-UNVERIFIED',
		'unit.query.MoveElementsSliceTest#testVerifyCatchesAnAppendOutOfOrder :: control :: M-MOVE-ELEMENTS-ORDER-UNVERIFIED',
		'unit.query.MoveFamilyCaptureTest#testABareWildcardCallerIsRepointedByteIdentically :: control :: M-WILDCARD-REPOINT-NONE',
		'unit.query.MoveFamilyCaptureTest#testALocalShadowKeepsItsBareReadByteIdentically :: control :: M-WILDCARD-BINDING-BLIND',
		'unit.query.MoveFamilyCaptureTest#testARivalWildcardKeepsItsBareCallerByteIdentically :: control :: M-WILDCARD-RIVAL-ORDER-BLIND',
		'unit.query.MoveFamilyCaptureTest#testASubModuleMoveRepointsNoWildcardCallerByteIdentically :: control :: M-WILDCARD-BINDS-BLIND',
		'unit.query.MoveMemberSplitSliceTest#testAFieldSomethingElseReachesStaysAndRefuses :: control :: '
			+ 'M-OWNED-FIELD-ANY-READER,M-OWNED-FIELD-ACCESS-BLIND,M-OWNED-FIELD-PROPERTY,M-OWNED-READERS-UNNAMED',
		'unit.query.MoveMemberSplitSliceTest#testAMemberOfAnInheritanceFamilyRefusesTheMove :: control :: '
			+ 'M-MOVE-OVERRIDE-MEMBER,M-MOVE-IMPLEMENTATION,M-MOVE-OVERRIDDEN-MEMBER,M-MOVE-UNRESOLVED-INTERFACE',
		'unit.query.MoveMemberSplitSliceTest#testAReceiverNotProvenAnUnrelatedClassRefusesTheMove :: control :: M-RECEIVER-STRUCTURE-LEFT',
		'unit.query.MoveMemberSplitSliceTest#testAReceiverTheOpCannotProveRefusesTheMove :: control :: '
			+ 'M-RECEIVER-UNKNOWN-ROUTED,M-RECEIVER-UNRELATED-ROUTED,M-VIA-PRIVATE-REACHED',
		'unit.query.MoveMemberSplitSliceTest#testASourceSubModuleTypeIsImportedAtTheDestination :: control :: M-CARRY-OWN-SUB-UNCARRIED',
		'unit.query.MoveMemberSplitSliceTest#testCarriedStatementsLandImportsFirstAndOnlyUsedUsings :: control :: '
			+ 'M-CARRY-ORDER-MET,M-CARRY-USING-UNUSED,M-CARRY-IMPORTLESS-BELOW,M-CARRY-USING-ORDER-MET',
		'unit.query.MoveMemberSplitSliceTest#testFieldsOnlyTheMovedGroupUsesMoveAlong :: control :: M-OWNED-FIELDS-OFF',
		'unit.query.MoveMemberSplitSliceTest#testKeepBareImportsTheDestinationStaticsInsteadOfQualifying :: control :: '
			+ 'M-KEEP-BARE-IGNORED',
		'unit.query.MoveMemberSplitSliceTest#testKeepBareRefusesWhatTheWildcardCouldRebind :: control :: '
			+ 'M-KEEP-BARE-CLASH-BLIND,M-KEEP-BARE-NOT-MAIN',
		'unit.query.MoveMemberSplitSliceTest#testReceiverQualifiedCallersRouteThroughTheHoldingField :: control :: M-RECEIVER-ROUTING-OFF',
		'unit.query.MoveMemberSplitSliceTest#testScaffoldWiresTheViaFieldBeforeTheConstructorBindsAMethod :: control :: '
			+ 'M-SCAFFOLD-VIA-AT-END',
		'unit.query.MoveMemberSplitSliceTest#testTwoMembersNeedingPrivateAccessShareOneTypeGrant :: control :: M-ACCESS-GRANT-PER-MEMBER',
		'unit.query.MoveSymbolSliceTest#testACommentOnlyFullyQualifiedMentionDoesNotRefuseTheMove :: control :: '
			+ 'M-MOVE-FQN-COMMENT-MASK-NONE',
		'unit.query.MoveSymbolSliceTest#testACommentOnlyMentionIsNotAReference :: control :: M-MOVE-NAMESCAN-COMMENT-COUNTED',
		'unit.query.MoveSymbolSliceTest#testACommentsTrailingPeriodDoesNotHideTheReferenceOwedARepairImport :: control :: '
			+ 'M-MOVE-NAMESCAN-FULLSTOP-BLIND',
		'unit.query.MoveSymbolSliceTest#testACutBeforeATrailingCommentKeepsOneSeparator :: control :: M-MOVE-CUT-TAKES-BOTH-RUNS',
		'unit.query.MoveSymbolSliceTest#testAMiddleDeclarationWithOneBlankSideKeepsIt :: control :: M-MOVE-SIBLINGS-FALSE',
		'unit.query.MoveSymbolSliceTest#testAModuleImportTheLadderDoesNotAgreeWithIsNotCarried :: control :: M-CARRY-OWN-SUB-UNCARRIED',
		'unit.query.MoveSymbolSliceTest#testASiblingPackageIsNotAnAncestorSoItIsLeftAlone :: control :: M-MOVE-PACKAGE-CHAIN-ANY',
		'unit.query.MoveSymbolSliceTest#testAStaticReceiverOnASiblingSubTypeIsCarried :: control :: '
			+ 'M-CARRY-OWN-SUB-UNCARRIED,M-CARRY-OWN-SUB-PRIVATE',
		'unit.query.MoveSymbolSliceTest#testAValuePositionIsStillNotPriced :: control :: M-MOVE-RECEIVER-ANY-IDENT',
		'unit.query.MoveSymbolSliceTest#testAliasDependencyIsCarriedIntoTheDestination :: control :: M-MOVE-ALIAS-SUFFIX-DROPPED',
		'unit.query.MoveSymbolSliceTest#testAliasImporterRepointedKeepingItsBinding :: control :: M-MOVE-ALIAS-SUFFIX-DROPPED',
		'unit.query.MoveSymbolSliceTest#testBareSamePackageDependencyIsPricedToo :: control :: M-MOVE-PACKAGE-CHAIN-ANY',
		'unit.query.MoveSymbolSliceTest#testCrossPackageAliasImporterNotMistakenForAnFqnReference :: control :: M-MOVE-FQN-ALIAS-RAW',
		'unit.query.MoveSymbolSliceTest#testCuttingAMiddleDeclarationLeavesExactlyOneSeparator :: control :: M-MOVE-BLANKRUN-END-NOOP',
		'unit.query.MoveSymbolSliceTest#testCuttingTheLastDeclarationOfAModuleTakesItsSeparator :: control :: M-MOVE-SIBLINGS-TRUE',
		'unit.query.MoveSymbolSliceTest#testDestinationModuleImportGainsNothingForASecondaryMove :: control :: '
			+ 'M-MOVE-USING-MIRROR-ANY-KIND',
		'unit.query.MoveSymbolSliceTest#testPrivateSiblingMainTypeIsNotABinding :: control :: M-MOVE-PRIVATE-SIBLING-BINDS',
		'unit.query.MoveSymbolSliceTest#testTheDestinationCollisionScanReadsTheDestinationsOwnComments :: control :: '
			+ 'M-MOVE-NAMESCAN-FULLSTOP-BLIND',
		'unit.query.MoveToHelperSliceTest#testABoundMemberIsRefused :: control :: M-HELPER-RECEIVER-VALUE-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testADynamicMemberIsRefused :: control :: M-HELPER-MODIFIER-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAGenericSourceIsRefused :: control :: M-HELPER-GENERIC-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAHelperIsCreatedAndEveryReferenceIsRewritten :: control :: '
			+ 'M-HELPER-THIS-KEPT,M-HELPER-MEMBER-UNQUALIFIED,M-HELPER-NO-GRANT,M-HELPER-FIELDS-TRAVEL',
		'unit.query.MoveToHelperSliceTest#testAMacroMemberIsRefused :: control :: M-HELPER-MODIFIER-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAMemberASubtypeOverridesIsRefused :: control :: M-MOVE-OVERRIDDEN-MEMBER',
		'unit.query.MoveToHelperSliceTest#testAMemberPassedAsAFunctionValueIsRefused :: control :: M-HELPER-VALUE-USE-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAModuleLevelValueIsRefused :: control :: M-HELPER-MODULE-VALUE-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testANonClassSourceIsRefused :: control :: M-HELPER-NON-CLASS-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAParameterNameTheMovedCodeSpellsIsRefused :: control :: M-HELPER-PARAM-CLASH-UNCHECKED',
		'unit.query.MoveToHelperSliceTest#testAPrivateTypeTheStayingCodeNamesIsRefused :: control :: M-HELPER-SHARED-TYPE-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAPropertyAccessorIsRefused :: control :: M-HELPER-ACCESSOR-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testASubtypesBareCallIsRewritten :: control :: M-HELPER-SUBTYPE-CALLERS-SKIPPED',
		'unit.query.MoveToHelperSliceTest#testASuperAccessIsRefused :: control :: M-HELPER-SUPER-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAnInstanceFieldIsRefused :: control :: M-HELPER-FIELD-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testAnInterfaceImplementationIsRefused :: control :: M-MOVE-IMPLEMENTATION',
		'unit.query.MoveToHelperSliceTest#testAnOverrideIsRefused :: control :: M-MOVE-OVERRIDE-MEMBER',
		'unit.query.MoveToHelperSliceTest#testAnUnresolvedReferenceIsRefused :: control :: M-HELPER-UNRESOLVED-ALLOWED',
		'unit.query.MoveToHelperSliceTest#testNestedCallsKeepTheOuterCallFirst :: control :: M-HELPER-CALL-ORDER',
		'unit.query.MoveToHelperSliceTest#testTheArmHintRetargetsAndFlagsAStaleFind :: control :: '
			+ 'M-HELPER-ARM-RETARGET-NONE,M-HELPER-ARM-STALE-NONE',
		'unit.query.MoveToHelperSliceTest#testTheDryRunWritesNothingAndTheWriteCreatesTheHelper :: control :: M-HELPER-DRY-RUN-WRITES',
		'unit.query.MoveToHelperSliceTest#testWhatOnlyTheMovedCodeNamesTravelsWithIt :: control :: '
			+ 'M-HELPER-CONSTANT-STAYS,M-HELPER-TYPE-STAYS,M-HELPER-TRAVELLING-IMPORTED',
		'unit.query.NameMentionScanTest#testACommentOnlyDestinationMentionDoesNotContestTheCarry :: control :: '
			+ 'M-MOVE-NAMESCAN-COMMENT-COUNTED',
		'unit.query.NameMentionScanTest#testAStringSpellingTheQualifiedPathStillRefusesWhileACommentDoesNot :: control :: '
			+ 'M-QUALPATH-COMMENT-COUNTED',
		'unit.query.NewFileSliceTest#testImportsSectionRefusesABareKeyword :: control :: M-NEWFILE-BARE-KEYWORD-WRAPPED',
		'unit.query.NewFileSliceTest#testImportsSectionRefusesAnUnusableLine :: control :: M-NEWFILE-IMPORT-ANY-LINE',
		'unit.query.NewFileSliceTest#testImportsSectionTakesStatements :: control :: M-NEWFILE-IMPORT-DOUBLED',
		'unit.query.NominalTypesTest#testABareCallIsTypedThroughTheEnclosingDeclarationsChain :: control :: '
			+ 'M-NOMINAL-SELECTED-BARE,M-SOURCE-SELECTED-BARE',
		'unit.query.NominalTypesTest#testABareCallOfALocalFunctionIsNotTheMembers :: control :: M-NOMINAL-UNQUALIFIED-MEMBER',
		'unit.query.NominalTypesTest#testABlindMemberReadWrittenWithAParameterHasNoAnswer :: control :: M-NOMINAL-BLIND-PARAMS',
		'unit.query.NominalTypesTest#testAConstructionIsTheTypeItWrites :: control :: M-NOMINAL-CONSTRUCTED',
		'unit.query.NominalTypesTest#testAConstructionReadsTheTypeArgumentsItWrites :: control :: M-CONSTRUCTION-CTOR-GAP',
		'unit.query.NominalTypesTest#testAGenericAbstractCastsThroughTheArgumentsItIsAppliedTo :: control :: '
			+ 'M-CASTS-APPLIED-ALIAS,M-CASTS-APPLIED-WRITTEN,M-CASTS-APPLIED-GRAPH-PARAM',
		'unit.query.NominalTypesTest#testALiteralIsItsType :: control :: M-NOMINAL-LITERAL',
		'unit.query.NominalTypesTest#testALocalWrittenWithNoTypeHoldsItsInitializersType :: control :: M-NOMINAL-LOCAL-INIT',
		'unit.query.NominalTypesTest#testAMethodsTypeParameterIsBoundByTheArguments :: control :: '
			+ 'M-CALLS-PARAM-INFER,M-CALLS-PARAM-BOUND,M-INDEX-RETURN-SOURCE-SPAN,M-CALLS-NULLABLE-UNBOUND',
		'unit.query.NominalTypesTest#testANamesakeDeclaringTheMemberDoesNotAnswerForOneInheritingIt :: control :: '
			+ 'M-NOMINAL-RECEIVER-INHERITED,M-NOMINAL-RECEIVER-DECLARATIONS,M-SOURCE-RECEIVER-DECLARATIONS',
		'unit.query.NominalTypesTest#testANamesakeNoSignatureOfWhichCompilesIsNotTheReceiver :: control :: M-NOMINAL-NAMESAKE-EXCLUDED',
		'unit.query.NominalTypesTest#testAReferenceItCannotCompleteHasNoAnswer :: control :: M-ANCESTOR-DEFAULT-MISSING,M-ANCESTOR-BARE-TYPE,M-ANCESTOR-SCOPE-OFF,M-ANCESTOR-DEFAULT-VISIBLE,M-NOMINAL-BOUND-SCOPE,M-INDEX-ALTERNATE-DEFAULTS',
		'unit.query.NominalTypesTest#testAReferenceLeavingArgumentsOutNamesTheirDefaults :: control :: M-ANCESTOR-DEFAULT-FILL,M-ANCESTOR-COMPLETE-OFF,M-ANCESTOR-LINK-DEFAULTS,M-MEMBER-READ-COMPLETE,M-NOMINAL-BOUND-COMPLETE,M-NOMINAL-RETURN-COMPLETE,M-INDEX-PARAM-DEFAULTS',
		'unit.query.NominalTypesTest#testATypeParameterReturnOrAnUnreadableTypeHasNoAnswer :: control :: M-NOMINAL-RETURN-PARAM-NAME,M-NOMINAL-UNREADABLE-WRITTEN',
		'unit.query.NominalTypesTest#testAnExpressionInsideAReificationIsNotTypedAsCode :: control :: M-NOMINAL-REIFIED,M-NOMINAL-REIFIED-NOMINAL,M-REIFIED-REOPEN',
		'unit.query.NominalTypesTest#testAnInheritedMemberReadsThroughItsChainsArguments :: control :: M-ANCESTOR-ARGS-OFF,M-MEMBER-READ-HOST-ARGS,M-NOMINAL-SELF-PARAMS',
		'unit.query.NominalTypesTest#testAnOptionalParameterReadsAsNullable :: control :: M-NOMINAL-OPTIONAL-PARAM',
		'unit.query.NominalTypesTest#testAnOptionalStructureFieldReadsAsNullable :: control :: M-MEMBER-OPTIONAL-READ,M-INDEX-OPTIONAL-FIELD',
		'unit.query.NominalTypesTest#testAnOverloadedCallReturnsWhatTheSelectedSignatureReturns :: control :: '
			+ 'M-NOMINAL-SELECTED-STATIC,M-NOMINAL-OVERLOAD-REFUSED,M-SOURCE-OVERLOAD-REFUSED,M-CALLS-FIRST-COMPILING,'
			+ 'M-CALLS-AGREED-RETURN,M-SOURCE-SELECTED-STATIC,M-NOMINAL-STATIC-ALIAS,M-NOMINAL-ARGUMENT-NULL,M-NOMINAL-ARGUMENT-BOUND',
		'unit.query.NominalTypesTest#testDeclarationsWritingAReturnDifferentlyHaveNoSource :: control :: M-NOMINAL-RETURN-AGREE',
		'unit.query.NominalTypesTest#testTheSourceModeKeepsTypeArguments :: control :: M-NOMINAL-SOURCE-CALL,M-NOMINAL-RETURN-TYPEPARAM',
		'unit.query.NominalTypesTest#testTheSuperclassChainDeclaresAMemberBeforeAnInterface :: control :: '
			+ 'M-NOMINAL-DECLARING-SUPER-POISON,M-NOMINAL-SELECTED-VALUE,M-SOURCE-SELECTED-VALUE',
		'unit.query.NominalTypesTest#testTheWrittenTypeReadersPeelTheirWrappers :: control :: M-ELEMENT-PEEL,M-OUTER-PATH-PEEL',
		'unit.query.NominalTypesTest#testThisInsideAnAbstractIsItsUnderlyingValue :: control :: M-NOMINAL-ABSTRACT-THIS',
		'unit.query.OpaqueCondRegionScanTest#testABraceDeltaRuleAnswersTwoOfTheThreeRegionClassesWrong :: control :: '
			+ 'M-OPAQUE-REGION-BRACE-DELTA',
		'unit.query.OpaqueCondRegionScanTest#testACommentAfterTheEndStaysOutOfTheQuote :: control :: M-OPAQUE-REGION-TRIVIA-KEPT',
		'unit.query.OpaqueCondRegionScanTest#testAPartlyRawRegionSaysSoAndQuotesOnlyItsRawBytes :: control :: M-REGION-INSIDE-NONE',
		'unit.query.OpaqueCondRegionScanTest#testARegionsOwnDirectivesAreNotAMentionOfTheNameTheyGuard :: control :: '
			+ 'M-COND-GAP-KEEPS-DIRECTIVES,M-COND-GAP-SCANS-NOTHING',
		'unit.query.OpaqueCondRegionScanTest#testAWhitespaceGapDoesNotDragTheSharedBodyIntoTheQuote :: control :: M-OPAQUE-REGION-WS-GAP',
		'unit.query.OpaqueCondRegionScanTest#testAnExplicitListBuildsNoNotes :: control :: M-REGION-NOTES-ALWAYS',
		'unit.query.OpaqueCondRegionScanTest#testDanglingElseIsOpaqueWhileItsBraceIdenticalTwinIsNot :: control :: M-OPAQUE-REGION-NONE',
		'unit.query.OpaqueCondRegionScanTest#testOnlyTheDirectiveRunsComeOutOfTheGap :: control :: '
			+ 'M-COND-GAP-KEEPS-DIRECTIVES,M-COND-GAP-SCANS-NOTHING',
		'unit.query.OpaqueCondRegionScanTest#testTheNoteNamesTheLineTheRegionAndTheReason :: control :: M-OPAQUE-REGION-NONE',
		'unit.query.OpaqueCondRegionScanTest#testTheQuoteIsTheGapsAndNotTheNodeSpan :: control :: M-OPAQUE-REGION-NODE-SPAN',
		'unit.query.OpaqueCondRegionScanTest#testTheSplitTryReportsBothOfItsRegions :: control :: M-OPAQUE-REGION-NONE',
		'unit.query.OperatorOverloadsTest#testAnOverloadNotDecidedInEveryBuildAnswersNothing :: control :: '
			+ 'M-OPS-BRANCHES-AGREE,M-OPS-GUARDED,M-OPS-INSTANCE,M-CASTS-BRANCH-MEMBERS,M-OPS-RETURN-OPEN,M-OPS-MAYFIT,M-OPS-OPEN-OPERAND',
		'unit.query.OperatorOverloadsTest#testTheFirstOverloadTakingTheOperandsBinds :: control :: M-OPS-FIRST-TAKEN,M-OPS-EXACT-EQUAL',
		'unit.query.OperatorOverloadsTest#testTheLeftOperandsOverloadTypesTheOperation :: control :: M-OPS-LEFT-OFF',
		'unit.query.OperatorOverloadsTest#testTheRightOperandsOverloadAndACommutativeOne :: control :: '
			+ 'M-OPS-RIGHT-OFF,M-OPS-COMMUTATIVE-OFF,M-SHAPE-COMMUTATIVE-UNSET',
		'unit.query.OrphanContinuationTest#testAddElementOfABareElseIsRefused :: control :: M-ORPHAN-GATE-OFF',
		'unit.query.OrphanContinuationTest#testAnOrphanTheSourceAlreadyHadDoesNotBlockAnEdit :: control :: M-ORPHAN-FLOOR-ZERO',
		'unit.query.OrphanContinuationTest#testCompilerRejectedShapesAreUnjustified :: control :: '
			+ 'M-ORPHAN-SEAM-END-ANY,M-ORPHAN-ANY-PARENT',
		'unit.query.OrphanContinuationTest#testFmtKeepsAnOrphanTheInputAlreadyHad :: control :: M-ORPHAN-FLOOR-ZERO',
		'unit.query.OrphanContinuationTest#testFmtRefusesAWriterThatStrandsAnElse :: control :: M-ORPHAN-FMT-GATE-OFF',
		'unit.query.OrphanContinuationTest#testPatchStrandingAnElseIsRefused :: control :: M-ORPHAN-GATE-OFF',
		'unit.query.OrphanContinuationTest#testRefusalNamesTheClauseTheEditMade :: control :: M-ORPHAN-NEW-CLAUSE-FIRST',
		'unit.query.OrphanContinuationTest#testSeamShapesAreJustified :: control :: M-ORPHAN-BRANCH-OPEN-NEVER,'
			+ 'M-ORPHAN-SEAM-END-NEVER,M-ORPHAN-SEAM-END-SELF-ONLY,M-ORPHAN-SEAM-END-UNTRIMMED,M-ORPHAN-NO-CASE-ARMS',
		'unit.query.PatchSliceTest#testATransferUnderADocRewrittenByTheSamePayloadRefused :: control :: M-PATCH-STRADDLED-DOC-UNWATCHED',
		'unit.query.PatchSliceTest#testATypeDocIsReachableThroughItsOwnAddress :: control :: M-PATCH-OWN-DOC-UNSEARCHED',
		'unit.query.PatchSliceTest#testDocCodeSampleIndentationSurvives :: control :: M-PATCH-COMMENT-SHAPE-CHECKED',
		'unit.query.PatchSliceTest#testDocPayloadWithASpaceGutterApplies :: control :: M-PATCH-COMMENT-SHAPE-CHECKED',
		'unit.query.PatchSliceTest#testFinalClassHeaderIsInTheSearchRegion :: control :: M-DECLSPAN-FINAL-WRAPPER-BLIND',
		'unit.query.PatchSliceTest#testGrowingPairsUnderOneClassDocAcceptedAtEveryDelta :: control :: M-PATCH-DOCEND-SHIFTS-EVERY-EDIT',
		'unit.query.PatchSliceTest#testInsertAheadOfADocumentedFinalClassRefused :: control :: M-PATCH-DOC-OWNER-WRAPPER-BLIND',
		'unit.query.PatchSliceTest#testInsertAheadOfTheDocBlockThroughTheMemberAccepted :: control :: M-PATCH-OWN-DOC-UNSEARCHED',
		'unit.query.PatchSliceTest#testRenamePlusAnUnrelatedInsertElsewhereApplies :: control :: M-PATCH-GROWTH-COUNTED-CONTAINER-WIDE',
		'unit.query.PatchSliceTest#testStringLiteralPerLineIndentStillRefused :: control :: M-PATCH-SHAPE-ALWAYS-SURVIVES',
		'unit.query.PatchSliceTest#testTransferUnderADocMovedByAnEarlierGrowingPairRefused :: control :: M-PATCH-DOCEND-NEVER-SHIFTS',
		'unit.query.PatternParseProbe#testTwoEllipsesInOneChildListAreRefused :: control :: M-STAR-ONE-PER-LIST',
		'unit.query.RefShapeKindProjectionTest#testEveryDeclaredKindNameIsOneTheGrammarProjects :: control :: '
			+ 'M-PROJECTED-KINDS-ALT-ONLY,M-DECL-HOST-KIND-STALE',
		'unit.query.RefShapeKindProjectionTest#testEveryDeclaredTokenIsOneTheParserCaptures :: control :: '
			+ 'M-AND-OPERATOR-TEXT-STALE,M-CONSTRUCTOR-NAME-PADDED',
		'unit.query.RefShapeKindProjectionTest#testEveryProjectedKindIsOneSomeSourceEmits :: control :: M-ELLIPSIS-STMT-TOKEN-STALE',
		'unit.query.RemoveElementSliceTest#testRemoveFinalClassTakesItsFinal :: control :: '
			+ 'M-DECLSPAN-FINAL-WRAPPER-BLIND,M-LIFT-FINAL-WRAPPER-SKIPPED',
		'unit.query.RemoveElementSliceTest#testRemoveOnePerLineElementTakesItsLine :: control :: M-REMOVE-COMMA-LINE-KEPT',
		'unit.query.RemoveElementSliceTest#testSelectedLiteralInsideAnExpressionIsRefused :: control :: M-LITERAL-STRANDED-ACCEPTED',
		'unit.query.RemoveElementSliceTest#testSelectedLiteralRemovesTheArrayItem :: control :: M-LITERAL-WRAPPER-SKIPPED',
		'unit.query.RemoveImportSliceTest#testCliUsingFlagRemovesTheUsing :: control :: M-REMOVEIMPORT-CLI-USING-FLAG-DROPPED',
		'unit.query.RemoveImportSliceTest#testUsingStatementPicksTheUsing :: control :: M-REMOVEIMPORT-KEYWORD-IGNORED',
		'unit.query.RemoveMemberSliceTest#testSiblingRegionsWithOneConditionAreRefusedByCount :: control :: '
			+ 'M-COND-FRAME-REGION-KEYED,M-COND-FRAME-CONDITION-RAW',
		'unit.query.RemoveMemberSliceTest#testTwoDeclarationsInOneBranchAreRefusedByCount :: control :: M-REMOVE-MEMBER-BRANCH-BLIND',
		'unit.query.RemoveParamSliceTest#testAClassMethodAndItsCallThatNowFitComeBackCanonical :: control :: M-SIGNATURE-EDIT-RAW-SPLICE',
		'unit.query.RemoveParamSliceTest#testAnInterfaceSignatureThatNowFitsComesBackCanonical :: control :: M-SIGNATURE-EDIT-RAW-SPLICE',
		'unit.query.RenameSliceTest#testContinuationDeclaratorInEffectBeforeACondArmRefused :: control :: '
			+ 'M-COND-CONTINUATION-NOT-IN-EFFECT',
		'unit.query.RenameSliceTest#testModelledSpliceConditionOccurrenceRenames :: control :: M-COND-GAP-KEEPS-DIRECTIVES',
		'unit.query.RenameSliceTest#testNameOfANamedFunctionExpressionSweepsTheEnclosingMethod :: control :: '
			+ 'M-BINDER-NAMED-FN-NO-STEP-OUT',
		'unit.query.RenameSliceTest#testNamedFnExprNameInEffectAroundACondArmRefused :: control :: M-COND-NAMED-FN-NOT-IN-EFFECT',
		'unit.query.ResolutionProjectFilesTest#testDerivedIndexesAreMemoised :: control :: M-MEMO-OFF',
		'unit.query.ResolutionProjectFilesTest#testSetResolutionIndexExpiresDerivedIndexes :: control :: M-NO-INVALIDATE',
		'unit.query.RewriteSliceTest#testANameSlotCaptureSplicesBare :: control :: M-REWRITE-NAME-CAPTURE-HOLE',
		'unit.query.RewriteSliceTest#testATemplateIsAlignedToEachSitesTerminator :: control :: M-REWRITE-TRAILER-UNALIGNED',
		'unit.query.RewriteSliceTest#testAValueCaptureNeverTakesATypeArgument :: control :: '
			+ 'M-MATCH-ONE-FLAT-RUN,M-MATCH-UNWRITTEN-DROPPED,M-REWRITE-UNWRITTEN-IGNORED',
		'unit.query.RewriteSliceTest#testAnUnwrittenTypeAnnotationIsNeverDropped :: control :: '
			+ 'M-MATCH-TYPE-SLOT-UNRECORDED,M-REWRITE-UNWRITTEN-IGNORED',
		'unit.query.SetModifierSliceTest#testAConditionalRegionOutsideTheKeywordRunIsStillServed :: control :: '
			+ 'M-SETMOD-GUARDED-ANY-VISIBILITY',
		'unit.query.SetModifierSliceTest#testAnEnumAbstractMemberStillTakesPublic :: control :: M-SETMOD-MODULE-BY-TYPE-KINDS',
		'unit.query.SetModifierSliceTest#testPrivateOnAFinalClassPrecedesTheFinal :: control :: M-DECLSPAN-FINAL-WRAPPER-BLIND',
		'unit.query.ShapeVocabTest#testAKindTwoSeamsNameIsAnsweredOnce :: control :: M-VOCAB-UNION-DUPLICATES',
		'unit.query.ShapeVocabTest#testAnUnsetSeamAddsNothing :: control :: M-VOCAB-UNSET-SEAM-ADDED',
		'unit.query.ShapeVocabTest#testConditionLoopsDropTheIteratingOnes :: control :: M-VOCAB-CONDITION-LOOP-KEEPS-FOR',
		'unit.query.ShapeVocabTest#testEveryHaxeLoopAndConditionalIsABranch :: control :: M-VOCAB-WHILE-EXPR-NOT-BRANCH',
		'unit.query.ShapeVocabTest#testHaxeLoopAndFunctionVocabulary :: control :: '
			+ 'M-VOCAB-NESTED-NO-NAMED-FN,M-VOCAB-DOWHILE-EXPR-NOT-LOOP',
		'unit.query.ShardPlanTest#testAClassHeavierThanAShardIsDealtAsSlices :: control :: M-SHARD-SPLIT-NEVER,M-SHARD-SPLIT-SLICE-WEIGHT',
		'unit.query.ShardPlanTest#testAMalformedSliceTokenIsRefused :: control :: M-SHARD-FILTER-PARSE-RANGE',
		'unit.query.ShardPlanTest#testAPinnedClassIsNeverSliced :: control :: M-SHARD-SPLIT-STICKY',
		'unit.query.ShardPlanTest#testAWholeTokenSelectsEveryTest :: control :: M-SHARD-FILTER-WHOLE-AS-SLICE',
		'unit.query.ShardPlanTest#testSlicesAreBoundedByTheTestCount :: control :: M-SHARD-SPLIT-NO-TEST-CAP,M-SHARD-SPLIT-UNKNOWN-COUNT',
		'unit.query.ShardPlanTest#testTheSlicesOfAClassCoverItsTestsExactlyOnce :: control :: '
			+ 'M-SHARD-FILTER-SLICE-ALL,M-SHARD-FILTER-SLICE-UNSORTED',
		'unit.query.ShardPlanTest#testTimingRowsOfOneClassAreSummed :: control :: M-SHARD-WEIGHTS-LAST-ROW',
		'unit.query.SourceTextTest#testLowerCamelLowersTheLeadingCapitalRun :: control :: M-LOWER-CAMEL-FIRST-ONLY',
		'unit.query.SpanTypeInfoPinTest#testTypeParamConstraintsAreKeyedByDeclarationAndName :: control :: M-SPANINFO-BOUND-MORE',
		'unit.query.StaticExtensionsTest#testAModuleBringsItsLastDeclaredTypeFirstAndItsFunctionsLast :: control :: M-EXT-DECL-TWO-HOSTS,M-EXT-MODULE-FIELDS-OPEN',
		'unit.query.StaticExtensionsTest#testATypedefBringsItsOwnThenTheAliasedTypes :: control :: M-EXT-ALIAS-STOP',
		'unit.query.StaticExtensionsTest#testAlternativesTheIndexCannotOrderMustAllPass :: control :: M-EXT-AMBIGUOUS-MODULE,M-EXT-GUARDED-LINKS',
		'unit.query.StaticExtensionsTest#testAnAbstractParameterTakesWhatItsClausesTake :: control :: M-UNIFY-ABSTRACT-OFF,M-CASTS-DYNAMIC-END',
		'unit.query.StaticExtensionsTest#testAnAliasInAUsedModuleBringsTheClassItNames :: control :: M-USING-HOSTS-ALIAS',
		'unit.query.StaticExtensionsTest#testAnInheritedUsingComesSuperclassFirst :: control :: M-EXT-INTERFACES-FIRST',
		'unit.query.StaticExtensionsTest#testTheFilesOwnUsingsComeBeforeTheAmbientOnes :: control :: M-EXT-AMBIENT-FIRST',
		'unit.query.StaticExtensionsTest#testTheLastUsingBindsAndARejectingOnePassesOver :: control :: M-BINDER-EXTENSION-LAST-USING,M-BINDER-EXTENSION-FIRST-PARAM',
		'unit.query.StaticExtensionsTest#testTheTypesOwnUsingBindsBeforeTheFilesAndPassesOverIntoThem :: control :: M-BINDER-EXTENSION-ATUSING,M-EXT-TYPE-USING-FORWARD',
		'unit.query.StaticExtensionsTest#testWhatAFirstParameterAccepts :: control :: M-EXT-NULL-PARAM-OPEN,M-EXT-DYNAMIC-PARAM-OPEN,M-UNIFY-GENERIC-GIVEN',
		'unit.query.StaticExtensionsTest#testWhatTheWalkDoesNotProve :: control :: M-EXT-FIELD-FIRST,M-EXT-PRIVATE-OPEN,M-BINDER-EXTENSION-GUARDED-USING',
		'unit.query.StdResolverTest#testAWrapperFirstOnPathYieldsToTheCompilerAfterIt :: control :: M-STD-FIRST-HAXE-ONLY',
		'unit.query.StdResolverTest#testHomebrewIsProbedBeforeUsrLocal :: guard :: ',
		'unit.query.StdResolverTest#testMultiEntryEnvAnswersTheStdEntry :: control :: M-STD-ENV-ENTRIES',
		'unit.query.StdResolverTest#testTheCompilersOwnSearchAnswersBesideAnUnresolvedLink :: control :: M-STD-COMPILER-SEARCH-NONE',
		'unit.query.StdResolverTest#testTheStdBesideTheCompilerIsFoundInEitherLayout :: control :: M-STD-SIBLING-HOMEBREW',
		'unit.query.StructuralMembershipTest#testAliasTargetPairAgrees :: control :: M-ALIAS-TARGET-SIMPLE-NAME',
		'unit.query.StructuralMembershipTest#testStructuralParameterAcceptGate :: control :: M-EXT-ITERABLE-ELEMENT',
		'unit.query.SymbolIndexRunMemoSliceTest#testConfinementGateReadsTheIndexGrantSlot :: control :: M-GRANT-SLOT-UNREAD',
		'unit.query.SymbolIndexRunMemoSliceTest#testSupertypeNameUnionIsBuiltOncePerIndex :: control :: M-SUPERTYPE-UNION-NOMEMO',
		'unit.query.SymbolIndexSliceTest#testDeclaringFilesCount :: control :: M-TYPEREF-NAMED-FIRST-TYPE',
		'unit.query.SymbolIndexSliceTest#testIsPrivateGuardedTypeIsPrivate :: control :: '
			+ 'M-INDEX-GUARDED-PRIVATE-SPLIT,M-INDEX-GUARDED-PRIVATE-PAST-MODIFIERS',
		'unit.query.SymbolIndexSliceTest#testPlatformFileDeclaresTheModuleBeforeItsDot :: control :: '
			+ 'M-MODULE-PLATFORM,M-MODULE-SCAN-PLATFORM',
		'unit.query.SymbolIndexSliceTest#testProvablyNotSubtypeRefusesAForwardingEnumAbstract :: control :: M-SUBTYPE-ROOT-NEGATIVE-LIST',
		'unit.query.TypeNameBindingTest#testADeclarationIsAtItsCanonicalPath :: control :: M-BINDINGS-DECLS-AT-SUBTYPE,M-CANONICAL-SUBTYPE',
		'unit.query.TypeNameBindingTest#testAGuardedImportAgainstAStdTypeIsUnknown :: control :: M-BINDING-STRICT-OUTSIDE',
		'unit.query.TypeNameBindingTest#testAGuardedImportAgainstAnotherBindingIsUnknown :: control :: M-AMBIENT-GUARDED-UNION',
		'unit.query.TypeNameBindingTest#testAGuardedImportBindsWhereTheOtherBuildProvablyBindsNothing :: control :: '
			+ 'M-BINDING-GUARDED-OTHER-BUILD',
		'unit.query.TypeNameBindingTest#testALibraryModuleIsReadFromTheResolutionScope :: control :: M-SCOPE-MODULE-TYPES-NONE',
		'unit.query.TypeNameBindingTest#testALibraryModuleThatDoesNotParseDeclaresNoTypeItNeverSpells :: control :: '
			+ 'M-SCOPE-UNPARSED-UNSPELLED',
		'unit.query.TypeNameBindingTest#testALibraryModuleWhoseBodyDoesNotParseStillDeclaresItsTypes :: control :: M-SKIM-NEVER',
		'unit.query.TypeNameBindingTest#testAParentPackageMainTypeBinds :: control :: M-BINDING-PACKAGE-TIER-CUT',
		'unit.query.TypeNameBindingTest#testAPrivateTypeIsNeverImportedOrSeenFromItsPackage :: control :: M-BINDING-PRIVATE-VISIBLE',
		'unit.query.TypeNameBindingTest#testARootModuleIsNotAFileOfItsNameInAnotherPackage :: control :: M-SCOPE-ROOT-MODULE-ANYWHERE',
		'unit.query.TypeNameBindingTest#testAStaticFieldImportBindsNoType :: control :: M-BINDING-FIELD-IMPORT-UNKNOWN',
		'unit.query.TypeNameBindingTest#testAStdModuleIsReadByTheStdListing :: control :: M-BINDING-OUTSIDE-UNREAD',
		'unit.query.TypeNameBindingTest#testAStdWildcardWithoutTheModuleBindsNothing :: control :: M-BINDING-STD-WILDCARD-BLIND',
		'unit.query.TypeNameBindingTest#testASubTypeIsInvisibleOutsideItsModule :: control :: M-BINDING-ROOT-SUBTYPES',
		'unit.query.TypeNameBindingTest#testAUseInTheOtherBranchOfTheImportsRegionIsNotCoGuarded :: control :: '
			+ 'M-COND-WITHIN-BRANCH-IGNORED',
		'unit.query.TypeNameBindingTest#testAUseInsideTheGuardedImportsBranchBindsIt :: control :: M-BINDING-COGUARD-IGNORED',
		'unit.query.TypeNameBindingTest#testAUseOutsideTheGuardedRegionIsUnknown :: control :: M-BINDING-STRICT-UNREAD-PASS',
		'unit.query.TypeNameBindingTest#testAWildcardBindsMainTypesOnly :: control :: M-BINDING-SUBTYPES-VISIBLE',
		'unit.query.TypeNameBindingTest#testAnImportLineListsTheNonPrivateTypesItBinds :: control :: M-BINDING-PRIVATE-VISIBLE',
		'unit.query.TypeNameBindingTest#testAnUnknownCarriesTheCandidatesItReads :: control :: '
			+ 'M-BINDING-EITHER-DROPS-REST,M-BINDING-EITHER-DROPS-GUARDED,M-BINDING-EITHER-OPEN-READ,M-BINDING-CANDIDATES-OWN-TYPE',
		'unit.query.TypeNameBindingTest#testAnUnreadableModuleImportIsUnknown :: control :: M-BINDING-UNINDEXED-MODULE-FREE',
		'unit.query.TypeNameBindingTest#testBindingsListEveryBuildsType :: control :: '
			+ 'M-TS-GUARDED-IMPORT,M-TS-WILD-MAYBE,M-BINDINGS-UNREADABLE-SUBTYPE,M-TS-WILD-GUARDED',
		'unit.query.TypeNameBindingTest#testStdTypesOutrankThePackage :: control :: M-BINDING-STDTYPES-CUT',
		'unit.query.TypeNameBindingTest#testTheLastExplicitImportWins :: control :: M-BINDING-FIRST-STATEMENT-WINS',
		'unit.query.TypeNameBindingTest#testTheModulesOwnTypeOutranksAnImport :: control :: M-BINDING-OWN-TIER-CUT',
		'unit.query.TypeNameBindingTest#testThePackageTierReadsTheStdCoresModulesPackageByPackage :: control :: M-TS-PACKAGE-PROJECT-FIRST',
		'unit.query.TypeNameBindingTest#testTheStdTypesNamesAreTheStdsOwn :: guard :: ',
		'unit.query.TypeNameBindingTest#testWildcardsAreAskedLastFirst :: control :: M-BINDING-FIRST-STATEMENT-WINS',
		'unit.query.TypingServiceTest#testARememberedNullIsNotAskedAgain :: control :: M-TYPING-ANSWER-FORGOTTEN',
		'unit.query.TypingServiceTest#testATypeQuestionIsKeptPerDeclaration :: control :: M-TYPING-TYPE-KEY-FILE',
		'unit.query.TypingServiceTest#testNamesakesInTwoFilesKeepTheirOwnAnswers :: control :: M-TYPING-KEY-FILE',
		'unit.query.TypingServiceTest#testTwoTypesOfOneFileKeepTheirOwnAnswers :: control :: M-TYPING-KEY-OFFSET',
		'unit.query.UncheckedConversionsTest#testAFactsFileSaysTheTargetItsBuildGeneratesCodeFor :: control :: M-FACTS-TARGET-RECORD',
		'unit.query.UncheckedConversionsTest#testAValueThatLeftTheTypeSystemSitsOnlyWhereSomeBuildKeepsIt :: control :: '
			+ 'M-UNCHECKED-TARGET,M-UNCHECKED-ESCAPED,M-UNCHECKED-BOXED,M-UNCHECKED-STRING,M-UNCHECKED-ARRAY,'
			+ 'M-UNCHECKED-POINTER,M-UNCHECKED-ALIAS,M-UNCHECKED-ALIAS-PLACE,M-UNCHECKED-BOXED-ALIAS,'
			+ 'M-NATIVE-SITE-INERT,M-NATIVE-SITE-CORE-TYPE,M-NATIVE-SITE-ALIAS,M-NATIVE-SITE-ARRAY-ELEMENTS',
		'unit.query.UncheckedConversionsTest#testAnInstanceOfAnotherClassSitsOnlyWhereSomeBuildKeepsIt :: control :: '
			+ 'M-UNCHECKED-CLASS-EXTERN,M-UNCHECKED-ALIKE',
		'unit.query.UnificationTest#testAClassUnifiesWithWhatItsChainReaches :: control :: M-UNIFY-CHAIN-OPEN',
		'unit.query.UnificationTest#testADeclarationUnderIfIsNotPlain :: control :: M-UNIFY-GUARDED-PLAIN',
		'unit.query.UnificationTest#testAGivenTypeWithParametersIsDecidedByItsChain :: control :: M-UNIFY-GENERIC-GIVEN',
		'unit.query.UnificationTest#testAHandUnifiedOrCyclicAbstractIsNotDecided :: control :: M-CASTS-HAND-UNIFIED,M-UNIFY-CAST-STACK',
		'unit.query.UnificationTest#testALinkWritingTooFewArgumentsBindsNothing :: control :: M-ANCESTOR-SHORT-ARGS',
		'unit.query.UnificationTest#testAPlainAbstractsClauseAllowsNoSecondCast :: control :: M-UNIFY-CAST-TRANSITIVE',
		'unit.query.UnificationTest#testAUnificationReadsTheClausesOfEveryBranchAndNoMember :: control :: M-CASTS-GRAPH-PARAMS,M-CASTS-BRANCHES-AGREE,M-CASTS-TYPE-SELECTED',
		'unit.query.UnificationTest#testAnAbstractUnifiesThroughItsClauses :: control :: M-UNIFY-ABSTRACT-OFF',
		'unit.query.UnificationTest#testAnEnumUnifiesWithItselfAlone :: control :: M-UNIFY-CHAIN-OPEN',
		'unit.query.UnificationTest#testAnyTakesEveryValue :: control :: M-CASTS-DYNAMIC-END',
		'unit.query.UnificationTest#testOnlyPlainTypesAreDecided :: control :: M-UNIFY-ALIAS-STOP,M-UNIFY-SELF-OPEN',
		'unit.query.UnificationTest#testTheChainPassesItsArgumentsInTheStartsTerms :: control :: M-ANCESTOR-ARGS-OFF',
		'unit.query.ValueNameBindingTest#testAModuleFieldComesBeforeAnyImport :: control :: '
			+ 'M-TS-MODULE-NAME,M-TS-MODULE-NAME-NESTED,M-TS-MODULE-NAME-ALIAS',
		'unit.query.ValueNameBindingTest#testAModuleValueUnderIfBindsInTheBuildsCompilingIt :: control :: '
			+ 'M-VALUES-MODULE-WITHIN,M-VALUES-MODULE-ALTERNATIVE,M-VALUES-IMPORTS-WITHIN,M-VALUES-IMPORTS-POSITION',
		'unit.query.ValueNameBindingTest#testAUsingBringsEveryTypeOfItsModule :: control :: M-USING-MODULE-TYPES',
		'unit.query.ValueNameBindingTest#testAWildcardBringsTheTypesStaticsOnly :: control :: '
			+ 'M-GRAPH-UNLISTED-WILDCARD,M-VALUES-OWNER-BY-NAME,M-VALUES-EXTERN,M-VALUES-BUILT-ABOVE',
		'unit.query.ValueNameBindingTest#testAnAliasWhosePathDoesNotDecodeMayBeAnyStatic :: control :: M-VALUES-ALIAS-UNDECODED',
		'unit.query.ValueNameBindingTest#testAnExplicitImportBindsTheStaticItsPathNames :: control :: '
			+ 'M-VALUES-SUBTYPE-IMPORT,M-VALUES-ENUM-CTOR,M-GRAPH-IMPORT-UNLISTED',
		'unit.query.ValueNameBindingTest#testAnImportBringsTheValuesOfTheTypesItPutsInScope :: control :: M-VALUES-IMPORTED-CTOR,'
			+ 'M-VALUES-WILDCARD-CTOR,M-VALUES-ALIAS-WHOLE-MODULE,M-VALUES-FIELD-IMPORT-TYPES,M-SCOPE-MODULE-IMPORT-BLIND',
		'unit.query.ValueNameBindingTest#testAnUnlistedImportIsTheOneACallMayBeRoutedThrough :: control :: '
			+ 'M-MACRO-VALUE-UNLISTED,M-MACRO-EXTENSIONS-ONLY',
		'unit.query.ValueNameBindingTest#testAnotherRegionOfTheSameConditionIsAnAlternative :: control :: '
			+ 'M-COND-ALTERNATIVE-REGIONS,M-COND-ALTERNATIVE-SPLIT',
		'unit.runtime.SameItemsTest#testDifferentLengthsDiffer :: guard :: ',
		'unit.runtime.SameItemsTest#testEqualItemsInOrderAreTheSame :: guard :: ',
		'unit.runtime.SameItemsTest#testSameLengthDifferentItemsDiffer :: control :: M-SAMEITEMS-LENGTH-ONLY',
		'unit.runtime.SortedOffsetsTest#testAnOffsetBelowTheRangeIsNotInIt :: control :: M-SORTED-OFFSETS-LOWER-BLIND',
		'unit.runtime.SortedOffsetsTest#testTheLowerBoundIsInclusive :: guard :: ',
		'unit.runtime.SortedOffsetsTest#testTheUpperBoundIsExclusive :: control :: M-SORTED-OFFSETS-UPPER-BLIND'
	];

}
