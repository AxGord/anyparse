package anyparse.grammar.haxe;

/**
 * Anonymous function expression payload: `function<T>(params):Ret body?`. The `function`
 * keyword is consumed at the enclosing `HxExpr.FnExpr` ctor via `@:kw('function')` — this
 * typedef only describes the type parameters, parameter list, optional return type and
 * optional body.
 *
 * The space (or lack thereof) BETWEEN `function` and `(` is gated by `@:fmt(anonFuncParens)`
 * on the enclosing ctor, NOT by a `funcParamParens`-style flag on the `params` Star here —
 * the Star is the first field of the typedef and `lowerStruct`'s outside-before-open path is
 * gated on `!isFirstField`, so any flag placed on `params` would be dead code; the
 * kw-trailing-space slot goes through `kwTrailingSpacePolicy` instead.
 *
 * Shape mirrors `HxFnDecl` with two adjustments for expression position: `params` uses
 * `HxLambdaParam` (optional type) rather than `HxParam` (mandatory type), since anon-fn
 * params commonly rely on inference (`function(res) trace(res)`); and the body is
 * `HxFnExprBody` rather than `HxFnBody` — its bare-expr branch does NOT carry `@:trail(';')`,
 * because `function(res) trace(res)` appears inside `Call(args)` where the next char is `,`
 * or `)`, not `;`.
 *
 * `typeParams` covers typed anonymous functions `function<T>(...)` — most commonly inside
 * `@:overload(...)` metadata args — and routes through the same `HxTypeParamDecl` grammar
 * as `HxFnDecl.typeParams`. Named function expressions (`function foo() body`) are handled
 * by the sibling `HxExpr.NamedFnExpr` ctor, placed BEFORE `FnExpr` so the longer-prefix-first
 * rule wins on an identifier after `function`; on a missing name the parser rolls back here.
 *
 * `body` is `@:optional` with `@:absentOn(...)` peek-ahead: when the next non-trivia char
 * after `params` (or `returnType`) is one of the listed terminators, the body is treated as
 * absent. This admits body-less anonymous-function forms — most notably
 * `@:overload(function())` metadata args. The terminator set covers every context `HxFnExpr`
 * is reached through transitively via `HxExpr.FnExpr`: `,`/`)` (call args, array/object lit,
 * type params, meta args), `;` (statement, var-decl), `}`/`]` (block close, switch case,
 * array close). A body-less form in a non-meta position is admitted too — round-trip
 * outranks Haxe semantic validation, and an absent body emits no `{...}` token.
 *
 * `HxFnExpr` is trivia-bearing transitively through `HxFnExprBody.BlockBody(HxFnBlock)` —
 * the paired type `HxFnExprT` is synthesised by `TriviaTypeSynth`.
 */
@:peg
typedef HxFnExpr = {
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams'),
		keepInnerWhenEmpty('anonFuncParamParensKeepInnerWhenEmpty'), wrapRules('anonFunctionSignatureWrap'), bodyAwareCompactIndent) var params: Array<HxLambdaParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType: Null<HxType>;
	@:optional @:absentOn(',', ')', ';', '}', ']') @:fmt(leftCurly('anonFunctionLeftCurly'), propagateAnonFnContext,
		bodyPolicyForCtor('ExprBody', 'anonFunctionBody')) var body: Null<HxFnExprBody>;
}
