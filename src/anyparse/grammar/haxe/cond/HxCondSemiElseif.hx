package anyparse.grammar.haxe.cond;

/**
 * One `#elseif <cond> <stmts>` clause of a `HxCondSemiRegion`. Its body is `HxElseifStmt`'s minus the per-element
 * break and the shared branch pad: a value region's branches finish an expression, so a branch keeps its source line
 * like the `#if` and `#else` bodies beside it.
 */
@:peg
typedef HxCondSemiElseif = {
	@:kw('#elseif')
	var cond: HxPpCondLit;
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent)
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	var body: Array<HxStatement>;
};
