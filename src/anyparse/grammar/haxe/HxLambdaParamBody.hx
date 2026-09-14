package anyparse.grammar.haxe;

/**
 * Body shape for a single lambda/anon-fn parameter slot — the `name [: Type] [= default]`
 * portion shared by both the required and optional branches of `HxLambdaParam`. The
 * optional marker dispatches at the Alt-enum level (`@:lead('?')
 * Optional(body:HxLambdaParamBody)` vs the fallthrough `Required(body:HxLambdaParamBody)`),
 * and both branches share this body without duplicating the field declarations — the mirror
 * of the `HxParam` / `HxParamBody` split.
 *
 * `defaultValue` is the exact `HxParamBody.defaultValue` slot — the `@:optional @:lead('=')`
 * shape of `HxVarDecl.init` minus that field's layout policies. Lambdas DO carry a
 * per-parameter default at the syntactic level: `function(a:Int = 1) return a` and `(b:Int =
 * 2) -> b` both compile and evaluate, and the stdlib's `js.html` / `php` externs declare
 * `@:overload(function(?type:String, replace:String = "") : HTMLDocument {})`.
 *
 * ONE AST shape moves, by design: `(a = 1) -> b` parses as `ThinParenLambdaExpr([Required(a
 * = 1)], b)`, a lambda with a defaulted parameter, rather than
 * `ThinArrow(ParenExpr(Assign(a, 1)), b)` — the reading Haxe itself takes (`var i = (a = 1)
 * -> a; i()` returns `1`). Its `=>` twin does NOT move, and the `HxExpr` atom order is the
 * reason: `ThinParenLambdaExpr` is tried BEFORE `ParenExpr`, so a `(...)` group followed by
 * `->` commits to the lambda; `ParenLambdaExpr` comes AFTER `ParenExpr`, so `(a = 1) => b` is
 * a parenthesised assignment plus the prec-0 map-entry infix `=>`. A multi-param `=>` list
 * such as `(x, a = 1) => b` cannot parse as an expression at all, so it does reach
 * `HxParenLambda` and picks the slot up there.
 *
 * Nothing else moves. `HxThinParenLambda` / `HxParenLambda` commit on the `->` / `=>` lead
 * only AFTER the param Star closes, and `lowerEnum` wraps every branch in `tryBranch`'s
 * position-restoring try/catch — so a `(...)` group with no arrow after it rolls the whole
 * lambda branch back and `ParenExpr` takes over: `(a = 1)` alone, `[(a = 1) => b]`, and
 * every call-arg / index / condition / case-pattern position keep their shape. The
 * paren-less thin form `x -> x = 1` never reaches this body — `HxExpr.ThinArrow` is a prec-0
 * right-assoc Pratt infix whose left operand is an already-parsed atom.
 *
 * Field order is `name` / `type` / `defaultValue`, byte-twin of `HxParamBody`: parse and emit
 * both walk a struct rule's fields in declaration order, the Haxe surface token order.
 *
 * Known gap inherited from the sibling slots: a block comment written between the `=` and
 * the default expression is dropped by the trivia writer, as in the `type` slot and
 * `HxVarDecl.init` (see `HxParamCommentWriteTest`).
 */
@:peg
typedef HxLambdaParamBody = {
	var name: HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') @:queryTypeSlot var type: Null<HxType>;
	@:optional @:lead('=') var defaultValue: Null<HxExpr>;
}
