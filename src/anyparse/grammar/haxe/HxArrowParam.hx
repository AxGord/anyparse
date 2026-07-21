package anyparse.grammar.haxe;

/**
 * Single parameter inside a new-form arrow function type
 * (`(args) -> ret`).
 *
 * Three branches:
 *
 *  - `OptionalNamed(body:HxArrowParamBody)` — the `?name:Type` form
 *    (e.g. `(string:String, ?radix:Int) -> Float`). Dispatched by
 *    `@:lead('?')`. Motivated by the Haxe stdlib: `js/Lib.hx:75` and
 *    `flash/Lib.hx:104` both declare
 *    `parseInt:(string:String, ?radix:Int) -> Float`, and
 *    `eval/luv/Udp.hx:98` nests a function type inside the optional
 *    slot (`?allocate:(size:Int) -> Buffer`). The parser previously
 *    consumed the `?` through `HxType.OptionalArg` and then choked on
 *    the `:` after the name.
 *
 *  - `Named(body:HxArrowParamBody)` — the `name:Type` form (e.g.
 *    `(name:String) -> Void`). The branch has no fixed `@:kw`/`@:lead`
 *    at the ctor level — its commit point is the `:` lead on
 *    `HxArrowParamBody.type`. When the parens contain a bare type whose
 *    initial token is an identifier (e.g. `(Int)`, `(pack.sub.Type)`,
 *    `(Foo<T>)`), `Named` parses the identifier as a candidate name,
 *    fails to match `:`, and rolls back.
 *
 *  - `Positional(type:HxType)` — fallback that parses any type. Catches
 *    every shape the named forms reject (bare typeref, parameterised,
 *    qualified, nested arrow, anon struct, `(Inner)` parens).
 *
 * Positional-optional `(?Int) -> Void` deliberately does NOT route
 * through `OptionalNamed`: the branch consumes `?`, reads `Int` as a
 * candidate NAME, then fails the mandatory `:` lead on
 * `HxArrowParamBody.type`. `lowerEnum`'s `tryBranch` wrapper restores
 * `ctx.pos` on that `ParseError`, `Named` rejects the leading `?`, and
 * `Positional` produces the pre-slice `OptionalArg(Named(Int))` shape
 * via `HxType`. So the `?`-marker lives on `HxType.OptionalArg` for a
 * positional arg and on this enum for a named one — both round-trip,
 * and no existing AST shape moved. That two-homes split is also why the
 * branch is called `OptionalNamed` and not `Optional` the way the
 * single-meaning siblings `HxParam` / `HxLambdaParam` / `HxAnonField`
 * name theirs: here a bare `Optional` would read as covering `?Int` too.
 *
 * Branch order: `OptionalNamed` must precede the catch-all `Positional`,
 * which would otherwise swallow `?b` as `OptionalArg(Named(b))` and
 * leave the enclosing Star choking on the `:`. Its position relative to
 * `Named` is a readability choice only — `HxArrowParamBody.name` is an
 * `HxIdentLit` (`[A-Za-z_][A-Za-z0-9_]*`), so `Named` can never match a
 * leading `?` and the two are token-disjoint. Catch-all-last mirrors
 * `HxParam` / `HxAnonField`.
 *
 * The new-form arrow type allows mixing positional and named params
 * across a single signature (`(Int, name:String) -> Bool` is well-formed
 * Haxe). Each `HxArrowParam` enum is matched independently, so the
 * macro pipeline imposes no positional-before-named ordering — that
 * constraint, if needed, is a typer-level concern.
 *
 * Varargs (`...rest:T`), default values and conditional compilation are
 * deferred. The new-form arrow type in real Haxe doesn't carry default
 * values, and varargs have no syntactic sugar at the type level (a
 * varargs function type is declared via `haxe.Constraints.Function`
 * instead). Cond-comp inside an arrow-type arg list
 * (`(#if js ?a:Int #end) -> Void`) does not parse — the sibling
 * `HxParam.Conditional` branch has no counterpart here, and no corpus
 * or stdlib file needs one.
 */
@:peg
enum HxArrowParam {

	@:lead('?') OptionalNamed(body: HxArrowParamBody);
	Named(body: HxArrowParamBody);
	Positional(type: HxType);

}
