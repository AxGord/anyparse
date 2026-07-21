package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <body>` clause inside a `HxConditionalFnBody`'s
 * `elseifs` Star - the function-BODY-slot twin of `HxElseifExpr` /
 * `HxElseifStmt` / `HxElseifMember`.
 *
 * Carries the `#elseif` keyword on its first field's metadata
 * (`HxCatchClause` precedent), so the parent's `@:tryparse` Star tries
 * the kw at each iteration and terminates naturally when the next token
 * is `#else` / `#end`.
 *
 * `body` is a single `HxFnBody`, matching the parent's Ref-vs-Star
 * choice: a function has exactly ONE body per compilation variant, so
 * each clause contributes exactly one - see `HxConditionalFnBody` for
 * the full rationale.
 *
 * `body` carries NO `@:fmt(padTrailing)`: the parent's `elseifs` Star
 * already pads its own trailing boundary, and a clause-local pad doubles
 * it (`return 2;  #else`). Same division of labour as `HxElseifExpr.expr`
 * under `HxConditionalExpr.elseifs`.
 */
@:peg
typedef HxElseifFnBody = {
	@:kw('#elseif') var cond: HxPpCondLit;
	var body: HxFnBody;
};
