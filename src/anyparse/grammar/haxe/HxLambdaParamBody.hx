package anyparse.grammar.haxe;

/**
 * Body shape for a single lambda/anon-fn parameter slot — the
 * `name [: Type] [= default]` portion shared by both the required and
 * optional branches of `HxLambdaParam`.
 *
 * Lifted out of the original `HxLambdaParam` typedef when the optional
 * marker `?name:Type` (Slice 31) was added: the marker dispatches at
 * the Alt-enum level (`@:lead('?') Optional(body:HxLambdaParamBody)`
 * vs the fallthrough `Required(body:HxLambdaParamBody)`), and both
 * branches share the same name / type body without duplicating the
 * field declarations. Mirror of the `HxParam` / `HxParamBody` split.
 *
 * `defaultValue` is the exact `HxParamBody.defaultValue` slot — the
 * `@:optional @:lead('=')` shape of `HxVarDecl.init` minus that field's
 * `@:fmt(...)` layout policies. The pre-slice docstring claimed arrow /
 * anon-function lambdas carry no per-parameter default at the syntactic
 * level; that was wrong. `function(a:Int = 1) return a` and
 * `(b:Int = 2) -> b` both compile and evaluate (verified on Haxe 4.3.7),
 * and the member-side `HxParamBody` has always modelled the same
 * `name : Type = default` shape. The gap surfaced in the Haxe stdlib,
 * where 14 `js.html` / `php` externs declare
 * `@:overload(function(?type:String, replace:String = "") : HTMLDocument {})`
 * — the `@:overload` wrapper is incidental, the bare
 * `var g = function(a:Int = 1) {};` failed identically. Real sites:
 * `js/html/CanvasRenderingContext2D.hx:73` (`= NONZERO`),
 * `js/html/Document.hx:471` (`= cast 4294967295` — a non-literal
 * default), `php/Global.hx:1052` (`= ""`).
 *
 * ONE AST shape moves, by design: `(a = 1) -> b` used to parse as
 * `ThinArrow(ParenExpr(Assign(a, 1)), b)` — a Pratt infix over a
 * parenthesised assignment — and now parses as
 * `ThinParenLambdaExpr([Required(a = 1)], b)`, a lambda with a defaulted
 * parameter. The new reading is the one Haxe itself takes (`var i = (a =
 * 1) -> a; i()` returns `1`), so this corrects the AST rather than
 * regressing it.
 *
 * Its `=>` twin does NOT move, and the `HxExpr` atom order is the whole
 * reason: `ThinParenLambdaExpr` is tried BEFORE `ParenExpr`, so a `(...)`
 * group followed by `->` commits to the lambda; `ParenLambdaExpr` comes
 * AFTER `ParenExpr`, so `(a = 1) => b` is taken as a parenthesised
 * assignment plus the prec-0 map-entry infix `=>`, exactly as before. A
 * multi-param `=>` list such as `(x, a = 1) => b` cannot parse as an
 * expression at all, so it does reach `HxParenLambda` and picks the slot
 * up there.
 *
 * Nothing else moves. `HxThinParenLambda` / `HxParenLambda` commit on the
 * `->` / `=>` lead only AFTER the param Star closes, and `lowerEnum`
 * wraps every branch in `tryBranch`'s position-restoring try/catch — so a
 * `(...)` group with no arrow after it rolls the whole lambda branch back
 * and `ParenExpr` takes over: `(a = 1)` alone, `[(a = 1) => b]`, and every
 * call-arg / index / condition / case-pattern position keep their
 * pre-slice shape. The paren-less thin form `x -> x = 1` never reaches
 * this body at all — `HxExpr.ThinArrow` is a prec-0 right-assoc Pratt
 * infix whose left operand is an already-parsed atom, so a bare-ident
 * left operand cannot absorb an `=`.
 *
 * Field order is `name` / `type` / `defaultValue`, byte-twin of
 * `HxParamBody`: parse and emit both walk a struct rule's fields in
 * declaration order, and `name : Type = default` is the Haxe surface
 * token order.
 *
 * Known gap inherited from the sibling slots, now reachable through this
 * one: a block comment written between the `=` and the default
 * expression is dropped by the trivia writer. `HxLambdaParam` loses
 * comments in its `type` slot the same way, as does `HxVarDecl.init`;
 * before this slice the same input was a parse error instead. Tracked
 * with the other param-comment gaps around `HxParamCommentWriteTest`.
 */
@:peg
typedef HxLambdaParamBody = {
	var name: HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type: Null<HxType>;
	@:optional @:lead('=') var defaultValue: Null<HxExpr>;
}
