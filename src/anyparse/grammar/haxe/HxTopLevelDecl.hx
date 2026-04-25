package anyparse.grammar.haxe;

/**
 * A top-level declaration with optional leading modifiers.
 *
 * Wraps `HxDecl` (the `class`/`typedef`/`enum`/`interface`/`abstract`
 * dispatch enum) with one preceding Star field of access modifiers
 * (`private`, `extern`, `final`, …). This is the top-level analog of
 * `HxMemberDecl`: a Star<HxModifier> consumed before the keyword
 * dispatch, so `private class Foo {}` and `private extern class Foo {}`
 * parse without the per-decl typedefs needing their own modifier
 * fields. Reusing the existing `HxModifier` enum keeps modifier syntax
 * uniform across declaration sites — semantic restrictions (rejecting
 * `static class`, `inline typedef`, …) belong to a later analysis pass,
 * not the parser.
 *
 * The Star carries no `@:lead`, `@:trail`, or `@:sep` and uses the
 * try-parse termination mode in `emitStarFieldSteps`: the loop attempts
 * to parse an `HxModifier` on each iteration and breaks when the next
 * token isn't a recognised modifier keyword. `@:tryparse` is stated
 * explicitly because the Trivia-mode path requires one of `@:trail`,
 * `isLastField`, or `@:tryparse` to pick a termination mode.
 *
 * `@:trivia` enables per-element trivia capture so leading comments,
 * blank-line markers, and inter-modifier whitespace round-trip the
 * same way `HxMemberDecl.modifiers` does.
 */
@:peg
typedef HxTopLevelDecl = {
	@:trivia @:tryparse var modifiers:Array<HxModifier>;
	var decl:HxDecl;
}
