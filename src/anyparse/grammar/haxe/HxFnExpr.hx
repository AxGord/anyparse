package anyparse.grammar.haxe;

/**
 * Anonymous function expression payload: `function(params) body?`.
 *
 * The `function` keyword is consumed at the enclosing
 * `HxExpr.FnExpr` ctor via `@:kw('function')` — this typedef only
 * describes the parameter list, optional return type, and optional
 * body.
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
 * `typeParams` covers typed anonymous functions
 * `function<T>(...)` — most commonly seen inside `@:overload(...)`
 * metadata args (`@:overload(function<T>(key:String):T {})`) but also
 * valid in any expression position. The optional `<T,...>` block sits
 * before `params` and routes through the same `HxTypeParamDecl`
 * grammar as `HxFnDecl.typeParams`.
 *
 * Named local function expressions (`function foo() body` in
 * expression position) are out of scope for this slice — if the
 * input has an identifier between `function` and `(`, the
 * enclosing `tryBranch` rolls back the `function` keyword and
 * tries the next atom candidate.
 *
 * `body` is `@:optional` with `@:absentOn(...)` peek-ahead: when
 * the next non-trivia char after `params` (or `returnType`) is one
 * of the listed terminators, the body is treated as absent. This
 * unblocks body-less anonymous-function forms — most notably
 * `@:overload(function())` metadata args, where the function arg
 * carries only a signature and no body. The terminator set covers
 * every context `HxFnExpr` is reached through transitively via
 * `HxExpr.FnExpr`: `,`/`)` (call-args, array/object lit, type
 * params, meta args), `;` (statement, var-decl), `}`/`]` (block
 * close, switch case, array close). This permits body-less in
 * non-meta positions too — anyparse philosophy is round-trip over
 * Haxe semantic validation; source-faithful output is preserved
 * because absent body emits no `{...}` token.
 *
 * `HxFnExpr` is trivia-bearing transitively through
 * `HxFnExprBody.BlockBody(HxFnBlock)` — the paired type
 * `HxFnExprT` is synthesised by `TriviaTypeSynth`.
 */
@:peg
@:fmt(propagateFnBodyEmpty('body'))
typedef HxFnExpr = {
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap')) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams'), keepInnerWhenEmpty('anonFuncParamParensKeepInnerWhenEmpty'), wrapRules('anonFunctionSignatureWrap'), bodyAwareCompactIndent) var params:Array<HxLambdaParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType:Null<HxType>;
	@:optional @:absentOn(',', ')', ';', '}', ']') @:fmt(leftCurly('anonFunctionLeftCurly'), propagateAnonFnContext) var body:Null<HxFnExprBody>;
}
