package anyparse.grammar.haxe;

/**
 * A single enum constructor with optional leading metadata.
 *
 * Wraps `HxEnumCtor` (the `ParamCtor` / `SimpleCtor` dispatch enum) with
 * one preceding Star of metadata tags (`@:kw('public')`, `@:foo(1)`,
 * `@:meta`, ...). This is the exact `HxMemberDecl` to `HxClassMember`
 * relationship applied at the enum-body level: `HxEnumDecl` iterates
 * this wrapper so the metadata prefix is parsed once before the
 * constructor-kind dispatch — no redundant re-parsing on failed
 * branches. The sister of `HxAnonMember` at the anon-struct level.
 *
 * Unlike `HxMemberDecl` there is no `modifiers` Star: enum constructors
 * take no `public` / `static` access modifiers, so only the metadata
 * gap needs closing.
 *
 * `meta` carries no `@:lead` / `@:trail` / `@:sep`; it uses the
 * try-parse termination mode (loop attempts an element each iteration,
 * breaks when the next token is not `@`). `@:tryparse` is stated
 * explicitly because the Trivia-mode path requires one of `@:trail`,
 * `isLastField`, or `@:tryparse` to pick a termination mode.
 *
 * `@:trivia` enables per-element trivia capture (leading comments,
 * trailing comment, blank-line and single-newline markers) — the same
 * channel `HxMemberDecl.meta` / `HxAnonMember.meta` use so `@:meta`
 * followed by a newline before the constructor round-trips.
 *
 * The common no-metadata case yields an empty `meta` Star, so the
 * per-branch `@:trail(';')` on `HxEnumCtor.ParamCtor` / `SimpleCtor`
 * and the close-peek Star on `HxEnumDecl.ctors` behave exactly as
 * before — same transparency property `HxAnonMember` has over
 * `HxAnonField.VarField` / `FinalField`.
 */
@:peg
typedef HxEnumMember = {
	@:trivia @:tryparse var meta: Array<HxMetadata>;
	var ctor: HxEnumCtor;
}
