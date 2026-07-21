package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <name>` clause inside a `HxConditionalFnName`
 * chain - the name-slot twin of `HxElseifType` / `HxElseifExpr`.
 *
 * The `#elseif` keyword commits the clause on `cond`'s metadata
 * (`HxCatchClause` precedent), so the parent's `@:tryparse` Star loop
 * tries the kw at each iteration and terminates when the next token is
 * `#else` / `#end`.
 *
 * `name` carries NO `@:fmt(padTrailing)`: the parent's `elseifs` Star
 * already pads its own trailing boundary, and a clause-local pad doubles
 * it (`bar  #else`). Same division of labour as `HxElseifExpr.expr` under
 * `HxConditionalExpr.elseifs`.
 */
@:peg
typedef HxElseifFnName = {
	@:kw('#elseif') var cond: HxPpCondLit;
	var name: HxIdentLit;
};
