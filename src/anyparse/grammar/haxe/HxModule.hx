package anyparse.grammar.haxe;

/**
 * Root grammar type for a multi-declaration Haxe module — zero or more top-level
 * declarations. `@:peg` marks the entry point; `@:schema(HaxeFormat)` binds the grammar to
 * `HaxeFormat` so the macro pipeline's `FormatReader` reads its `whitespace` field at
 * compile time; `@:ws` activates whitespace skipping before every literal and regex match.
 * `decls` is a `Star<Ref>` with NO `@:lead` / `@:trail` — the absence of `@:trail` selects
 * the EOF-terminated loop variant in `StarFieldLowering.emitStarFieldSteps` (D22): the
 * parser keeps parsing decls until `ctx.pos` reaches `ctx.input.length`, and any trailing
 * non-whitespace text fails the inner `parseHxTopLevelDecl` call. The element type is
 * `HxTopLevelDecl` (metadata + modifiers + `HxDecl`). An empty source yields `{decls: []}`.
 *
 * The `@:fmt` cluster on `decls` is the module-level blank-line cascade, evaluated per
 * element pair in the trivia-mode EOF Star path (`TriviaEofLowering.triviaEofStarExpr`) in
 * this priority: after-ctor overrides, then same-kind-by-level, then cross-subset
 * transition, then before-ctor, then the source-driven binary `blankBefore` slot. Every
 * count is an OVERRIDE, not a floor. `blankLinesAtHeadIfCtor(...'beforePackage')` /
 * `blankLinesAfterCtor(...'afterPackage')` — blank lines before / after a `PackageDecl` /
 * `PackageEmpty`. `blankLinesOnTransitionAcross('decl', imports, '|', usings,
 * 'beforeUsing')` — fires on a cross-subset boundary in either direction.
 * `blankLinesBetweenSameCtorByLevel(...)` — two entries, imports and usings, firing
 * `betweenImports` between consecutive same-kind elements whose path payloads differ at
 * `betweenImportsLevel` per the `betweenImportsPathDiffers` adapter.
 * `blankLinesBetweenSameCtorTailTransparent` /
 * `...HeadTransparent('decl', 'Conditional', …)` — a `#if … #end` element is classified by
 * its last / first leaf through the `betweenImports{Tail,Head}LeafClassify` adapters, so
 * `#end → import` and `import → #if … import` boundaries take the same cascades. That
 * five-meta cluster is MIRRORED, same arg strings, on `HxConditionalDecl.body` /
 * `elseBody` and `HxElseifDecl.body`; edit all three sites in lockstep.
 *
 * Predicate-gated variants `blankLinesAfterCtorIf` / `blankLinesBeforeCtorIf('decl',
 * 'multiline', …)` gate on the grammar-derived structural `multiline` predicate
 * (`WriterLowering.buildMultilinePredicate`), the fork's `betweenTypes` vs
 * `betweenSingleLineTypes` discrimination; `blankLinesBeforeCtorIfPrevNot(…, '|',
 * 'Conditional', …)` suppresses the before-override after a conditional, and
 * `blankLinesAfterCtorIfTailLeafNull('decl', 'Conditional', 'tailLeafKeepsBlankAfterConditional',
 * 'afterConditionalBlock')` forces the after-count when the conditional's tail leaf is
 * neither an import / using nor a type decl. `multilineWhenLeadingTriviaSpansLines('meta',
 * 'decl')` OR-s into the `multiline` predicate an element whose leading trivia holds a
 * comment or whose metadata sits on its own line.
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef HxModule = {
	@:trivia
	@:fmt(blankLinesAtHeadIfCtor('decl', 'PackageDecl', 'PackageEmpty', 'beforePackage'))
	@:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty', 'afterPackage'))
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', '|', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'
	))
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', 'UsingDecl', 'UsingWildDecl', '|', 'ClassDecl',
		'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FinalDecl', 'AbstractClassDecl', 'EnumAbstractDecl', 'TypedefDecl', 'FnDecl',
		'beforeType'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', 'betweenImportsLevel', 'betweenImports',
		'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'UsingDecl', 'UsingWildDecl', 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorTailTransparent('decl', 'Conditional', 'betweenImportsTailLeafClassify'))
	@:fmt(blankLinesBetweenSameCtorHeadTransparent('decl', 'Conditional', 'betweenImportsHeadLeafClassify'))
	@:fmt(blankLinesAfterCtorIf(
		'decl', 'multiline', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FinalDecl', 'AbstractClassDecl',
		'EnumAbstractDecl', 'FnDecl', 'TypedefDecl', 'afterMultilineDecl'
	))
	@:fmt(blankLinesAfterCtorIfTailLeafNull('decl', 'Conditional', 'tailLeafKeepsBlankAfterConditional', 'afterConditionalBlock'))
	@:fmt(blankLinesBeforeCtorIfPrevNot(
		'decl', 'multiline', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FinalDecl', 'AbstractClassDecl',
		'EnumAbstractDecl', 'FnDecl', 'TypedefDecl', '|', 'Conditional', 'beforeMultilineDecl'
	))
	@:fmt(blankLinesBetweenSameCtorIfNot(
		'decl', 'multiline', 'TypedefDecl', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FinalDecl', 'AbstractClassDecl',
		'EnumAbstractDecl', 'betweenSingleLineTypes'
	))
	@:fmt(multilineWhenLeadingTriviaSpansLines('meta', 'decl'))

	/**
	 * ω-measured-multiline-decl — the RENDERED half of the same `multiline`
	 * predicate. `multilineWhenLeadingTriviaSpansLines` above and the
	 * per-payload `@:fmt(multilineWhen…)` metas answer from SHAPE: a class is
	 * multi-line iff it declares members. An empty-bodied
	 * `class C extends B implements I1 … I4 {}` whose heritage wraps is
	 * single-line by that rule and three lines on the page. This flag makes
	 * the EOF-Star loop build each declaration's Doc once up front and read
	 * the answer off it — a committed break, or a width the module-level pen
	 * cannot hold WITH somewhere to break it — which is the question fork
	 * `MarkEmptyLines.getTypeInfo` asks through `isSameLine`. Only the
	 * after- / before-side rules consume it; `betweenSingleLineTypes` keeps
	 * its structural answer (see `WriterLowering.readCascadeInfosFromStar`).
	 * EOF-mode Stars only — every other lowering path rejects the flag at
	 * compile time, since no other scaffold declares the array it reads.
	 */
	@:fmt(measuredMultilineDecls)
	@:fmt(blankBeforeOrphanLineCommentTrail)
	@:fmt(blankBeforeLineCommentLed)
	@:fmt(afterFileHeaderCommentBlanks)
	@:fmt(betweenMultilineCommentsBlanks)
	var decls: Array<HxTopLevelDecl>;
}
