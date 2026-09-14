package anyparse.grammar.haxe;

/**
 * Single parameter inside a new-form arrow function type (`(args) -> ret`).
 *
 * Three branches: `OptionalNamedParam(body:HxArrowParamBody)` — the `?name:Type` form
 * (`(string:String, ?radix:Int) -> Float`), dispatched by `@:lead('?')`;
 * `NamedParam(body:HxArrowParamBody)` — the `name:Type` form, whose commit point is the `:`
 * lead on `HxArrowParamBody.type` (when the parens contain a bare type whose initial token
 * is an identifier, `NamedParam` parses it as a candidate name, fails to match `:`, and
 * rolls back); and `Positional(type:HxType)` — the fallback that parses any type (bare
 * typeref, parameterised, qualified, nested arrow, anon struct, parens).
 *
 * Positional-optional `(?Int) -> Void` deliberately does NOT route through
 * `OptionalNamedParam`: the branch consumes `?`, reads `Int` as a candidate NAME, then fails
 * the mandatory `:` lead; `lowerEnum`'s `tryBranch` wrapper restores `ctx.pos`, `NamedParam`
 * rejects the leading `?`, and `Positional` produces `OptionalArg(NamedParam(Int))` via
 * `HxType`. So the `?` marker lives on `HxType.OptionalArg` for a positional arg and on this
 * enum for a named one — both round-trip. That two-homes split is why the branch is called
 * `OptionalNamedParam` and not `Optional` the way `HxParam` / `HxLambdaParam` / `HxAnonField`
 * name theirs: a bare `Optional` would read as covering `?Int` too.
 *
 * Branch order: `OptionalNamedParam` must precede the catch-all `Positional`, which would
 * otherwise swallow `?b` as `OptionalArg(NamedParam(b))` and leave the enclosing Star
 * choking on the `:`. Its position relative to `NamedParam` is readability only —
 * `HxArrowParamBody.name` is an `HxIdentLit`, so the two are token-disjoint. Each
 * `HxArrowParam` is matched independently, so `(Int, name:String) -> Bool` parses and any
 * positional-before-named ordering is a typer-level concern.
 *
 * Varargs, default values and conditional compilation are deferred: the new-form arrow type
 * carries no default values, varargs have no syntactic sugar at the type level, and
 * `(#if js ?a:Int #end) -> Void` has no `HxParam.Conditional` counterpart here.
 *
 * The `…Param` SUFFIX on the two named branches is load-bearing: a ctor name becomes the
 * node KIND in the query projection, and `HaxeQueryPlugin` lists `Named` in both
 * `typeRefShape().typeRefKinds` and `refShape().typeAnnotationKinds` for `HxType.Named`. A
 * branch here spelled `Named` therefore projected an arrow PARAMETER LABEL as a type
 * reference — `apq uses Doc` reported the label of `(Doc:Int) -> Void`, and `CrossRename`
 * rewrote it. Do not rename these back to `Named` / `OptionalNamed`; a kind that appears in
 * a plugin kind SET must name one concept across the whole grammar.
 */
@:peg
enum HxArrowParam {

	@:lead('?') OptionalNamedParam(body: HxArrowParamBody);
	NamedParam(body: HxArrowParamBody);
	Positional(type: HxType);

}
