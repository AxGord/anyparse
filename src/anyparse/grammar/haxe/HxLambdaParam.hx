package anyparse.grammar.haxe;

/**
 * Single parameter slot inside a parenthesised lambda / anon-fn
 * (`(params) -> body`, `(params) => body`, `function (params) {...}`).
 *
 * Two branches (Slice 31 introduced the Alt-enum split — previously a
 * plain `name + optional type` typedef with `@:spanned('LambdaParam')`):
 *
 *  - `Optional(body:HxLambdaParamBody)` — the optional form
 *    `?name:Type` or `?name`. Dispatched by `@:lead('?')`. Closes the
 *    lambda-side gap explicitly noted in `HxParam`'s docstring
 *    ("Lambda-style `?param` routes through `HxLambdaParam` (separate
 *    grammar)").
 *
 *  - `Required(body:HxLambdaParamBody)` — the canonical form `name` or
 *    `name:Type`. No keyword / lead — the branch matches when the next
 *    token is the parameter name (`HxIdentLit`).
 *
 * Byte-twin of `HxParam`'s Required/Optional split, minus the `Rest`
 * and `Conditional` branches. Both branches carry an optional default
 * value through `HxLambdaParamBody.defaultValue`
 * (`function(a:Int = 1) {}`, `(b:Int = 2) -> b`) — see that typedef's
 * docstring for why the pre-slice "lambdas carry no default value"
 * claim was wrong and why the slot cannot swallow `(a = 1)` as a
 * lambda. Rest-style (`...name`) lambda params have no fork-fixture
 * coverage and stay out of scope.
 *
 * Branch order: lead-dispatched `Optional` (`?`) FIRST, the catch-all
 * `Required` LAST. Mirrors the established `HxParam` / `HxAnonField`
 * convention; `?` shares no overlap with any valid name terminal so
 * dispatch is unambiguous.
 *
 * Used by `HxParenLambda.params`, `HxThinParenLambda.params`, and
 * `HxFnExpr.params`. All three sites carry the trivia-Star Lowering
 * path; the split is transparent to that machinery — the parser
 * dispatches at the enum level, and the writer emits the leading `?`
 * literal via the standard `@:lead` path (sibling to `HxParam.Optional`).
 *
 * Refs binding consequence (`HaxeQueryPlugin`): the previous
 * `@:spanned('LambdaParam')` wrapper produced AST nodes with kind
 * `LambdaParam`; after the split, lambda params surface as `Required`
 * / `Optional` nodes (the enum-ctor names). Both kinds were already in
 * `DECL_HOST_KINDS` for the `HxParam` sibling, so binding continues to
 * resolve `(x) -> x + 1` style reads without further changes.
 */
@:peg
enum HxLambdaParam {

	@:lead('?') Optional(body: HxLambdaParamBody);
	Required(body: HxLambdaParamBody);

}
