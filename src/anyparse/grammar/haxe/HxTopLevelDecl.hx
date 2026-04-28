package anyparse.grammar.haxe;

/**
 * A top-level declaration with optional leading metadata and modifiers.
 *
 * Wraps `HxDecl` (the `class`/`typedef`/`enum`/`interface`/`abstract`
 * dispatch enum) with two preceding Star fields: metadata tags
 * (`@:allow(pack.Cls)`, `@:enum`, `@test("foo")`, …) first, then
 * access modifiers (`private`, `extern`, `final`, …). This is the
 * top-level analog of `HxMemberDecl`: `@:allow(pack.X) @:enum`-style
 * tags and modifiers parse without each per-decl typedef having to
 * carry its own meta/modifier fields. Reusing `HxMetadata` and
 * `HxModifier` keeps the syntax uniform across declaration sites —
 * semantic restrictions (rejecting `@:overload class Foo`,
 * `static class`, …) belong to a later analysis pass, not the parser.
 *
 * Both Stars carry no `@:lead`, `@:trail`, or `@:sep` and use the
 * try-parse termination mode in `emitStarFieldSteps`: the loop attempts
 * to parse an element on each iteration and breaks when the next token
 * isn't a recognised start character (`@` for metadata, a reserved
 * keyword for modifiers). `@:tryparse` is stated explicitly because the
 * Trivia-mode path requires one of `@:trail`, `isLastField`, or
 * `@:tryparse` to pick a termination mode.
 *
 * `@:trivia` on both Stars enables per-element trivia capture so leading
 * comments, blank-line markers, and inter-element whitespace round-trip
 * the same way `HxMemberDecl.meta` and `HxMemberDecl.modifiers` do —
 * `@:keep\n@:expose\nclass Foo` preserves the inter-meta newline, and
 * `@:enum class M` vs `@:enum\nclass M` round-trip verbatim because the
 * trivia channel records the newline before the dispatch keyword.
 */
@:peg
typedef HxTopLevelDecl = {
	@:trivia @:tryparse var meta:Array<HxMetadata>;
	@:trivia @:tryparse var modifiers:Array<HxModifier>;
	var decl:HxDecl;
}
