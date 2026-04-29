package anyparse.grammar.haxe;

/**
 * Anonymous function expression payload: `function(params) body`.
 *
 * The `function` keyword is consumed at the enclosing
 * `HxExpr.FnExpr` ctor via `@:kw('function')` — this typedef only
 * describes the parameter list, optional return type, and body.
 * The space (or lack thereof) BETWEEN `function` and `(` is gated by
 * `@:fmt(anonFuncParens)` on the enclosing ctor, NOT by a
 * `funcParamParens`-style flag on the `params` Star here — the Star
 * is the first field of the typedef and `lowerStruct`'s
 * outside-before-open path is gated on `!isFirstField`, so any flag
 * placed on `params` would be dead code. Slice ω-anon-fn-paren-policy
 * routes the kw-trailing-space slot through `kwTrailingSpacePolicy`
 * instead.
 *
 * Shape mirrors `HxFnDecl` but with two adjustments tailored for
 * expression position:
 *  - `params` uses `HxLambdaParam` (optional type) rather than
 *    `HxParam` (mandatory type); anon-fn params commonly omit
 *    types and rely on inference, e.g. `function(res) trace(res)`.
 *  - body is `HxFnExprBody` rather than `HxFnBody`. The bare-expr
 *    branch on `HxFnExprBody` does NOT carry `@:trail(';')` —
 *    `function(res) trace(res)` appears inside `Call(args)` where
 *    the next char is `,` or `)`, not `;`.
 *
 * Named local function expressions (`function foo() body` in
 * expression position) are out of scope for this slice — if the
 * input has an identifier between `function` and `(`, the
 * enclosing `tryBranch` rolls back the `function` keyword and
 * tries the next atom candidate.
 *
 * `HxFnExpr` is trivia-bearing transitively through
 * `HxFnExprBody.BlockBody(HxFnBlock)` — the paired type
 * `HxFnExprT` is synthesised by `TriviaTypeSynth`.
 */
@:peg
typedef HxFnExpr = {
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams')) var params:Array<HxLambdaParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType:Null<HxType>;
	@:fmt(leftCurly) var body:HxFnExprBody;
}
