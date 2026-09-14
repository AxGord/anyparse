package anyparse.grammar.haxe;

/**
 * A top-level declaration with optional leading metadata and modifiers: wraps `HxDecl` (the
 * `class`/`typedef`/`enum`/`interface`/`abstract` dispatch enum) with two preceding Star
 * fields — metadata tags first, then access modifiers (`private`, `extern`, …). The
 * top-level analog of `HxMemberDecl`; reusing `HxMetadata` and `HxModifier` keeps the syntax
 * uniform across declaration sites, and semantic restrictions (`@:overload class Foo`,
 * `static class`) belong to a later analysis pass.
 *
 * Both Stars carry no `@:lead`, `@:trail` or `@:sep` and use the try-parse termination mode
 * in `emitStarFieldSteps`, breaking when the next token is not a recognised start (`@` for
 * metadata, a reserved keyword for modifiers); `@:tryparse` is stated explicitly because the
 * Trivia-mode path requires one of `@:trail`, `isLastField` or `@:tryparse` to pick a mode.
 * `@:trivia` on both Stars enables per-element trivia capture so leading comments,
 * blank-line markers and inter-element whitespace round-trip the same way
 * `HxMemberDecl.meta` / `modifiers` do — `@:enum class M` vs `@:enum\nclass M` round-trip
 * verbatim because the trivia channel records the newline before the dispatch keyword.
 *
 * `@:fmt(setBoolFlagFromStarCtor('_classExtern', 'modifiers', 'Extern'))` on `decl`
 * (ω-extern-class-no-blanks) propagates a runtime flag down the descendant writer chain
 * whenever the sibling `modifiers` Star contains an `Extern` ctor; the writer for
 * `HxClassDecl.members` reads `opt._classExtern` to suppress `interMemberBlankLines`-driven
 * blanks, mirroring the fork's `externClassEmptyLines`. The mechanism is meta-driven and
 * reusable for any "set bool opt flag from sibling Star ctor presence" rule.
 *
 * ω-orphan-prefix-decl: `decl` is `@:optional @:absentOnEof` — the module-scope twin of
 * `HxMemberDecl.member`. A trailing `#if sys` / `#end` region holding no declaration is
 * claimed by `meta` (`HxMetadata.Conditional` accepts an empty body) exactly as at member
 * scope, which leaves `decl` facing the ONE terminator `@:absentOn` cannot name: end of
 * input. `@:absentOnEof` adds `ctx.pos >= ctx.input.length` as a disjunct of the same peek
 * chain. The zero-width spin this could have opened is closed by the enclosing Star's own
 * shape: `HxModule.decls` is an EOF-terminated trivia Star whose exit test runs after
 * `collectTrivia` and BEFORE each element parse, and `decl` is absent only when that same
 * test would have said "stop" — so a prefix-only element can only be produced AT EOF, and an
 * unterminated `#if` fails instead of looping. Two writer consequences of the field being
 * optional: `setBoolFlagFromStarCtor` is served by the optional-Ref writer seat too, and
 * every blank-line cascade on `HxModule.decls` classifies on this field with a `case null`
 * arm answering kind `0`.
 */
@:peg
typedef HxTopLevelDecl = {
	@:trivia @:tryparse var meta: Array<HxMetadata>;
	@:trivia @:tryparse @:fmt(forceInlineSep, keepBlankAfterStarCtor('meta', 'Conditional')) var modifiers: Array<HxModifier>;
	@:fmt(setBoolFlagFromStarCtor('_classExtern', 'modifiers', 'Extern'))
	@:optional @:absentOnEof @:fmt(bareRefSepWhenPresent, keepBlankAfterStarCtor('meta', 'Conditional')) var decl: Null<HxDecl>;
}
