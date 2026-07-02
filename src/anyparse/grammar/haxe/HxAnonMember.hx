package anyparse.grammar.haxe;

/**
 * A single anonymous-structure-type field with optional leading
 * metadata.
 *
 * Wraps `HxAnonField` (the `?short` / `var` / `final` / `function` /
 * `name:Type` dispatch enum) with one preceding Star of metadata tags
 * (`@:optional`, `@:lead('(')`, `@:foo(1)`, ...). This is the exact
 * `HxMemberDecl` to `HxClassMember` relationship applied at the
 * anon-struct level: `HxType.Anon` iterates this wrapper so the
 * metadata prefix is parsed once before the field-kind dispatch — no
 * redundant re-parsing on failed branches.
 *
 * `modifiers` mirrors `HxMemberDecl` (slice ω-anon-field-visibility): Haxe tolerates class-notation visibility on structure fields (`typedef T = { public var x:String; }` — live dogfood shape), so the same try-parse modifier Star precedes the field dispatch. The common no-modifier case yields an empty Star.
 *
 * `meta` carries no `@:lead` / `@:trail` / `@:sep`; it uses the
 * try-parse termination mode (loop attempts an element each iteration,
 * breaks when the next token is not `@`). `@:tryparse` is stated
 * explicitly because the Trivia-mode path requires one of `@:trail`,
 * `isLastField`, or `@:tryparse` to pick a termination mode.
 *
 * `@:trivia` enables per-element trivia capture (leading comments,
 * trailing comment, blank-line and single-newline markers) — the same
 * channel `HxMemberDecl.meta` uses so `@:meta` followed by a newline
 * before the field round-trips.
 *
 * The common no-metadata case yields an empty `meta` Star, so the
 * `@:sepAlt(';')` close-driven loop on `HxType.Anon` and the
 * per-branch `@:trail(';')` on `HxAnonField.VarField` / `FinalField`
 * behave exactly as before.
 */
@:peg
typedef HxAnonMember = {
	@:trivia @:tryparse var meta: Array<HxMetadata>;
	@:trivia @:tryparse var modifiers: Array<HxMemberModifier>;
	var field: HxAnonField;
}
