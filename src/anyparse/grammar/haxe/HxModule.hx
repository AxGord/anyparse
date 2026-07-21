package anyparse.grammar.haxe;

/**
 * Root grammar type for a multi-declaration Haxe module — a file
 * containing zero or more top-level declarations.
 *
 * Grammar metadata:
 *  - `@:peg` marks this as a grammar entry point.
 *  - `@:schema(HaxeFormat)` binds the grammar to `HaxeFormat` so the
 *    macro pipeline's `FormatReader` reads its `whitespace` field at
 *    compile time.
 *  - `@:ws` activates cross-cutting whitespace skipping before every
 *    literal and regex match in the generated parser.
 *
 * The single field `decls` is a `Star<Ref>` with **no** `@:lead` /
 * `@:trail` — the top level of a Haxe file has no open / close
 * delimiters, just a sequence of declarations separated by
 * whitespace. The absence of `@:trail` on the Star field selects
 * the EOF-terminated loop variant in `Lowering.emitStarFieldSteps`
 * (see D22 in session_state.md): the generated parser keeps parsing
 * decls until `ctx.pos` reaches `ctx.input.length`. Any trailing
 * non-whitespace text fails the inner `parseHxTopLevelDecl` call and
 * propagates a `ParseError`.
 *
 * Element type is `HxTopLevelDecl`, the wrapper carrying optional
 * leading modifiers (`private`, `extern`, `final`, …) before the
 * `HxDecl` enum dispatch. The wrapper mirrors `HxMemberDecl` at
 * top-level scope; reusing the same `HxModifier` enum keeps modifier
 * syntax uniform across declaration sites.
 *
 * An empty source is valid and yields `{decls: []}` — zero-decl
 * modules mirror the existing zero-member class case.
 *
 * `@:fmt(blankLinesAtHeadIfCtor('decl', 'PackageDecl', 'PackageEmpty', 'beforePackage'))`
 * (slice ω-before-package) is the head-of-Star sister to
 * `blankLinesAfterCtor`: at the start of the module's decl list, if the
 * first element matches `PackageDecl` / `PackageEmpty`, the engine emits
 * exactly `opt.beforePackage` blank lines BEFORE the package directive.
 * Override semantics, head-of-Star only — applies once at file head.
 * Default `0` keeps the file leading edge tight against `package …;`;
 * `1` inserts one blank line so the file starts with a leading newline
 * (mirrors fork's `emptyLines.beforePackage` behaviour). The same
 * `blankLinesAtHeadIfCtor` mechanism is reusable for any future "blank
 * lines at head before ctor X" slice (e.g. file-leading typedef header)
 * by pointing at a different opt field. The head emit is spliced once
 * at the start of the elseBody in
 * `WriterLowering.triviaEofStarExpr` (and mirrored in
 * `triviaTryparseStarExpr` for inner Stars), driven by
 * `WriterLowering.buildHeadCtorBlankInfo` and `CascadeEmit.headEmit`.
 *
 * `@:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty', 'afterPackage'))`
 * (slice ω-after-package) instructs the trivia-mode EOF Star path in
 * `WriterLowering.triviaEofStarExpr` to emit exactly `opt.afterPackage`
 * blank lines after any element whose `decl` field is `PackageDecl`
 * or `PackageEmpty`. Override semantics, not floor: the source-captured
 * blank-line count is replaced with this value when the previous
 * element matches a named ctor, so `0` strips an existing blank line
 * and higher counts insert that many regardless of source. Other
 * element pairs keep the trivia channel's binary `blankBefore` flag —
 * one blank line when the source had any, none otherwise. The same
 * `blankLinesAfterCtor` shape is reusable for any future "blank line
 * after ctor X" slice (e.g. after typedef-block) by pointing at a
 * different opt field.
 *
 * `@:fmt(blankLinesOnTransitionAcross('decl', 'ImportDecl',
 * 'ImportWildDecl', '|', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'))`
 * (slice ω-imports-using-transition) fires `opt.beforeUsing` blank
 * lines on a cross-subset boundary: the `'|'` separator splits the
 * matched ctors into two subsets (left of `'|'`: imports; right:
 * usings). The cascade fires when prev's tail-classified kind sits in
 * one subset AND curr's head-classified kind sits in the other —
 * mirroring fork's `MarkEmptyLines.markImports` cross-kind branch
 * (`prevInfo.isImport != newInfo.isImport`). Replaces the older
 * asymmetric `blankLinesBeforeCtor('UsingDecl', …)` knob, which only
 * fired Import→Using; transition is symmetric (both directions). With
 * head-transparency for `Conditional` wired below, also covers
 * `using → #if … import …` boundaries. The cascade order in the
 * trivia EOF Star path is: `blankLinesAfterCtor` entries (in source
 * order, prev match) win first, then `blankLinesBetweenSameCtorByLevel`
 * entries (same-kind pair with path-level mismatch), then
 * `blankLinesOnTransitionAcross` entries (cross-subset transition),
 * then source-driven binary blank-line slot. Mutually exclusive with
 * `blankLinesBetweenSameCtorByLevel` per pair (same-kind vs cross-kind
 * partition).
 *
 * `@:fmt(blankLinesBetweenSameCtorByLevel('decl', CtorA1, [CtorA2, …],
 * 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'))`
 * (slice ω-imports-using-between) is the same-kind, path-level-aware
 * knob — fires `opt.betweenImports` blank lines between two
 * consecutive elements that BOTH match the named ctor set AND whose
 * path payloads (first positional ctor arg) differ at
 * `opt.betweenImportsLevel` granularity per the grammar-supplied
 * `opt.betweenImportsPathDiffers` adapter. Two entries here — one for
 * the imports set, one for the usings set — keep the gate symmetric
 * with fork's `prev.isImport == curr.isImport` partition. The adapter
 * field follows the established `endsWithCloseBrace` /
 * `caseBodyRefusesFlat` pattern: declared on `WriteOptions` base,
 * default-wired by the grammar plugin, engine emits a pure
 * `opt.<name>(...)` EField call.
 *
 * `@:fmt(blankLinesBetweenSameCtorTailTransparent('decl', 'Conditional',
 * 'betweenImportsTailLeafClassify'))` (slice ω-cond-comp-tail-transparency)
 * and the head-side mirror
 * `@:fmt(blankLinesBetweenSameCtorHeadTransparent('decl', 'Conditional',
 * 'betweenImportsHeadLeafClassify'))` (slice ω-imports-using-transition)
 * extend the same-kind path-level cascade with "transparent wrapper"
 * support on both ends of a boundary: when an element matches the named
 * ctor (here `HxDecl.Conditional`), the engine routes through the
 * `betweenImportsTailLeafClassify` adapter for the prev-side classifier
 * (last non-empty branch's last element) and the
 * `betweenImportsHeadLeafClassify` adapter for the curr-side classifier
 * (first non-empty branch's first element), recursively unwrapping
 * nested wrappers in each direction. Each adapter returns
 * `{ctorName, path}` for recognised leaf ctors; the engine filters
 * `_r.ctorName` against each between info's matched ctorNames list at
 * runtime, so a single shared walker pair feeds both the Imports and
 * Usings between infos AND the cross-subset transition cascade. Tail
 * transparency closes `#end → import` boundaries (Bug #2.B); head
 * transparency closes `import → #if … import …` boundaries (Bug #2.A,
 * via transition cascade with prev=Import + curr=Conditional with
 * import-head leaf in a different subset position).
 *
 * The five-meta cluster from `blankLinesOnTransitionAcross` through
 * `blankLinesBetweenSameCtorHeadTransparent` is mirrored on the inner
 * conditional bodies (`HxConditionalDecl.body`, `HxConditionalDecl.elseBody`,
 * `HxElseifDecl.body`) by slice ω-bug-2c-inner-star — same arg strings,
 * so cascade behavior between sibling decls inside `#if … #end` matches
 * the top-level Star. Edits to the meta arg strings here MUST be
 * mirrored at all three sites in lockstep (no built-in cluster-include
 * mechanism for Haxe positional metadata).
 *
 * Predicate-gated variants `@:fmt(blankLinesAfterCtorIf(classifierField,
 * predicateName, Ctor1, …, optField))` and the symmetric `…BeforeCtorIf`
 * (slice ω-after-multiline) accept an extra `predicateName` arg right
 * after the classifier — the kind=1 case body emits a grammar-derived
 * structural check resolved at compile time by
 * `WriterLowering.buildMultilinePredicate` (currently the only
 * registered predicate is `'multiline'`). Empty-body single-line decls
 * (`class C<T> {}`, `function f() {}`) fall through the predicate to
 * kind=0 and the override stays inert. Drives the "blank line around
 * multi-line type decls" rule (matches haxe-formatter's `betweenTypes`
 * vs `betweenSingleLineTypes` discrimination) without regressing
 * single-line type-decl runs. Zero runtime reflection — the macro
 * walks the grammar shape and emits direct `Array.length > 0` /
 * enum-`switch` checks.
 *
 * `@:fmt(blankLinesBeforeCtorIfPrevNot(classifierField, predicateName,
 * TargetCtor1, …, '|', ExcludeCtor1, …, optField))` (slice
 * ω-before-multiline-prev-not) is the prev-aware variant of
 * `blankLinesBeforeCtorIf`: same predicate-gated target side, but the
 * override is ADDITIONALLY suppressed when the previous sibling's
 * classifier ctor sits in the excluded set after the `'|'` separator —
 * the cascade then falls through to the source-driven `blankBefore`
 * count instead of forcing `opt.<optField>`. Used here to exclude
 * `Conditional` (`#if … #end`): a cond-comp directive immediately before
 * a multiline type decl with NO source blank no longer gets a spurious
 * forced blank. When the source DID have a blank, the source-driven
 * fallback emits it — but whether fork keeps that blank depends on the
 * conditional's TAIL content, handled by the after-side override below.
 * Resolved by `WriterLowering.buildBeforeCtorBlankInfoIfPrevNot`; the
 * excluded set drives a second binary classify-switch tracked into the
 * prev-side.
 *
 * `@:fmt(blankLinesAfterCtorIfTailLeafNull(classifierField, Ctor,
 * tailAdapterField, optField))` (slice ω-after-conditional-block) is the
 * after-side counterpart: it forces `opt.<optField>` blank lines AFTER a
 * previous element matching `Ctor` (`Conditional`) whose tail-leaf
 * classify (via the `tailAdapterField` adapter, here
 * `tailLeafKeepsBlankAfterConditional`) returns null — i.e. the
 * conditional's last decl is NEITHER an import / using NOR a type-level
 * decl. Mirrors fork's actual module-level behaviour: there is no
 * keep-existing-blanks pass at top level (that runs only inside function
 * bodies), so a `#if … #end` followed by a decl starts at zero blanks;
 * fork's `markImports` re-adds one (`beforeType`) when the conditional's
 * tail is an import / using, and `betweenTypes` (default 1) re-adds one
 * when the tail is a type-level decl. Default
 * `afterConditionalBlock = 0` therefore strips the source blank for an
 * `#if … #error … #end → class` boundary (sharp_error) while leaving
 * byte-identical the import-tailed case (issue_322 / issue_85: tail is
 * `import` → adapter non-null → source-driven blank kept) and the
 * type-tailed case (issue_4_no_empty_line_before_sharp_end_2: tail is a
 * `class` → adapter non-null → kept). As an after-info it sits OUTERMOST
 * in the cascade priority (after > between > transition > before >
 * source), so it wins over the `blankLinesBeforeCtorIfPrevNot` exclusion
 * above for the error-tailed conditional. Resolved by
 * `WriterLowering.buildAfterCtorBlankInfoIfTailLeafNull`; the matched
 * classify case binds `_v0` (the conditional payload) so the adapter has
 * the wrapper to walk tail-first.
 *
 * `@:fmt(multilineWhenLeadingTriviaSpansLines('meta', 'decl'))` (slice
 * ω-leading-trivia-multiline) is an element-level override OR-ed into
 * the `'multiline'` predicate that the three blank rules above gate on.
 * The structural `'multiline'` predicate only inspects the decl payload
 * (`_v0`), so a single-line `typedef` preceded by its own leading
 * doc-comment, or carrying metadata on its OWN line, is wrongly
 * classified single-line. This flag widens the per-element kind to
 * multi-line when EITHER the element's leading-trivia slot holds a
 * comment (`_t.leadingComments.length > 0`) OR the named meta field is
 * non-empty AND the source broke before the dispatch keyword
 * (`_t.node.meta.length > 0 && _t.node.declBeforeNewline`). This mirrors
 * fork `MarkEmptyLines.getTypeInfo`, whose `oneLine =
 * isSameLine(findLowestIndex(typeToken), lastToken)` — `findLowestIndex`
 * reaches the type's leading comment and leading metadata, so any
 * internal newline (comment→decl, meta→decl) makes the type multi-line.
 * The inter-decl blank SEPARATOR between two decls lives in a different
 * trivia slot (`_t.blankBefore` / `_t.newlineBefore`) and is NOT counted
 * — a pure-blank leading gap is still single-line. The first arg names
 * the metadata Star field, the second the bare-Ref dispatch field whose
 * synth `<field>BeforeNewline` slot records the meta→keyword break.
 * Resolved by `WriterLowering.readCascadeInfosFromStar` →
 * `buildPredicateGatedKind`. Closes `whitespace/issue_202` (doc-comment
 * before typedef) and `emptylines/issue_255` (metadata-on-own-line).
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
	@:fmt(blankBeforeOrphanLineCommentTrail)
	@:fmt(blankBeforeLineCommentLed)
	@:fmt(afterFileHeaderCommentBlanks)
	@:fmt(betweenMultilineCommentsBlanks)
	var decls: Array<HxTopLevelDecl>;
}
