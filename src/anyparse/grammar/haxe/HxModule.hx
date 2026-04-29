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
 * `WriterLowering.triviaEofStarExpr` to emit at least `opt.afterPackage`
 * blank lines after any element whose `decl` field is `PackageDecl`
 * or `PackageEmpty`. Source-captured blank lines compose with the
 * minimum: when the source already had ≥ `opt.afterPackage` blanks,
 * the captured count wins; the knob only forces a minimum, never a
 * maximum. The same `blankLinesAfterCtor` shape is reusable for any
 * future "blank line after ctor X" slice (e.g. after import-group,
 * after typedef-block) by pointing at a different opt field.
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef HxModule = {
	@:trivia @:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty', 'afterPackage')) var decls:Array<HxTopLevelDecl>;
}
