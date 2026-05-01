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
 * `@:fmt(blankLinesBeforeCtor('decl', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'))`
 * (slice ω-imports-using-blank) is the mirror knob — instructs
 * `triviaEofStarExpr` to emit exactly `opt.beforeUsing` blank lines
 * before any element whose `decl` field matches `UsingDecl` /
 * `UsingWildDecl` and whose preceding element does NOT match the same
 * set. Drives the `import → using` transition: when prev is `import`
 * (or any non-`using` decl) and curr is `using`, force the configured
 * count regardless of source; consecutive `using` decls cascade
 * through to source-driven `blankBefore`. The cascade order in the
 * trivia EOF Star path is: `blankLinesAfterCtor` entries (in source
 * order, prev match) win first, then `blankLinesBeforeCtor` entries
 * (curr match without prev match), then source-driven binary blank-
 * line slot. Multiple `blankLinesAfterCtor` / `blankLinesBeforeCtor`
 * entries on the same Star are supported (ω-after-typedecl multi-info
 * refactor) — open to future "blank line before X-group" slices (e.g.
 * `beforeType` for the import/using → type-decl transition) by adding
 * an analogous `@:fmt(...)` call with a different ctor set and opt
 * field.
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
	@:fmt(blankLinesBeforeCtor('decl', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'))
	@:fmt(blankLinesAfterCtorIf('decl', 'multiline', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FnDecl', 'afterMultilineDecl'))
	@:fmt(blankLinesBeforeCtorIf('decl', 'multiline', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FnDecl', 'beforeMultilineDecl'))
	var decls:Array<HxTopLevelDecl>;
}
