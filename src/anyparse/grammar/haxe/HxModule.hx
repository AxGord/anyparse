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
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef HxModule = {
	@:trivia
	@:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty', 'afterPackage'))
	@:fmt(blankLinesOnTransitionAcross('decl', 'ImportDecl', 'ImportWildDecl', '|', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'))
	@:fmt(blankLinesBetweenSameCtorByLevel('decl', 'ImportDecl', 'ImportWildDecl', 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'))
	@:fmt(blankLinesBetweenSameCtorByLevel('decl', 'UsingDecl', 'UsingWildDecl', 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'))
	@:fmt(blankLinesBetweenSameCtorTailTransparent('decl', 'Conditional', 'betweenImportsTailLeafClassify'))
	@:fmt(blankLinesBetweenSameCtorHeadTransparent('decl', 'Conditional', 'betweenImportsHeadLeafClassify'))
	@:fmt(blankLinesAfterCtorIf('decl', 'multiline', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FnDecl', 'afterMultilineDecl'))
	@:fmt(blankLinesBeforeCtorIf('decl', 'multiline', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FnDecl', 'beforeMultilineDecl'))
	var decls:Array<HxTopLevelDecl>;
}
