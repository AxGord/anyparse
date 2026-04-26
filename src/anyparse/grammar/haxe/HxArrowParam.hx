package anyparse.grammar.haxe;

/**
 * Single parameter inside a new-form arrow function type
 * (`(args) -> ret`).
 *
 * Two branches:
 *
 *  - `Named(body:HxArrowParamBody)` — the `name:Type` form (e.g.
 *    `(name:String) -> Void`). Tried first via `tryBranch`. The branch
 *    has no fixed `@:kw`/`@:lead` at the ctor level — its commit point
 *    is the `:` lead on `HxArrowParamBody.type`. When the parens
 *    contain a bare type whose initial token is an identifier (e.g.
 *    `(Int)`, `(pack.sub.Type)`, `(Foo<T>)`), `Named` parses the
 *    identifier as a candidate name, fails to match `:`, and rolls back.
 *
 *  - `Positional(type:HxType)` — fallback that parses any type. Catches
 *    every shape the named form rejects (bare typeref, parameterised,
 *    qualified, nested arrow, anon struct, `(Inner)` parens).
 *
 * Branch order matters: `Named` first so the `IDENT :` shape is greedy.
 * Mirror of the `HxAnonField` / `HxParam` Alt-enum-split pattern, with
 * the rollback driver shifted from a fixed `@:lead('?')` literal (those
 * grammars) to the `:` lead inside the body typedef.
 *
 * The new-form arrow type allows mixing positional and named params
 * across a single signature (`(Int, name:String) -> Bool` is well-formed
 * Haxe). Each `HxArrowParam` enum is matched independently, so the
 * macro pipeline imposes no positional-before-named ordering — that
 * constraint, if needed, is a typer-level concern.
 *
 * Varargs (`...rest:T`) and default values are deferred — the new-form
 * arrow type in real Haxe doesn't carry default values, and varargs
 * have no syntactic sugar at the type level (a varargs function type is
 * declared via `haxe.Constraints.Function` instead).
 */
@:peg
enum HxArrowParam {
	Named(body:HxArrowParamBody);
	Positional(type:HxType);
}
