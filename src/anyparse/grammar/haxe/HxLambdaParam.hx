package anyparse.grammar.haxe;

/**
 * Single parameter slot inside a parenthesised lambda / anon-fn (`(params) -> body`,
 * `(params) => body`, `function (params) {...}`).
 *
 * Two branches: `Optional(body:HxLambdaParamBody)` — the `?name:Type` / `?name` form,
 * dispatched by `@:lead('?')`; and `Required(body:HxLambdaParamBody)` — the canonical `name` /
 * `name:Type` form, matched when the next token is the parameter name (`HxIdentLit`). Branch
 * order is lead-dispatched `Optional` FIRST, the catch-all `Required` LAST, the `HxParam` /
 * `HxAnonField` convention; `?` overlaps no valid name terminal, so dispatch is unambiguous.
 *
 * A twin of `HxParam`'s Required/Optional split, minus the `Rest` and `Conditional` branches.
 * Both branches carry an optional default value through `HxLambdaParamBody.defaultValue`
 * (`function(a:Int = 1) {}`, `(b:Int = 2) -> b`) — see that typedef for why the slot cannot
 * swallow `(a = 1)` as a lambda. Rest-style (`...name`) lambda params stay out of scope.
 *
 * Used by `HxParenLambda.params`, `HxThinParenLambda.params` and `HxFnExpr.params`; all three
 * sites carry the trivia-Star Lowering path, which the split leaves untouched — the parser
 * dispatches at the enum level and the writer emits the leading `?` via the standard `@:lead`
 * path.
 *
 * Refs binding (`HaxeQueryPlugin`): lambda params surface as `Required` / `Optional` nodes,
 * the enum-ctor names, which `DECL_HOST_KINDS` already lists for the `HxParam` sibling, so
 * `(x) -> x + 1` style reads resolve.
 */
@:peg
enum HxLambdaParam {

	@:lead('?') Optional(body: HxLambdaParamBody);
	Required(body: HxLambdaParamBody);

}
