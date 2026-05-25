package anyparse.grammar.haxe;

/**
 * Do-while body variants (slice 53).
 *
 * Splits the body slot into three exhaustive shapes so that
 * `do <bare-expr> while (...)` (no `;` between body expr and
 * `while`) is parseable without touching the global
 * `stmtExprNoSemi` gate. Sole-blocker for `issue_195_macro_do_while`
 * (`do $block while(...)`) and
 * `issue_221_indentation_of_prefix_increment` (`do a++ while(...)`,
 * `do ++a while(...)`).
 *
 * - `BlockBody` — `{ stmts; }` block, byte-twin of
 *   `HxStatement.BlockStmt` (same lead/trail/sep/fmt quartet).
 * - `InnerDoWhile` — `do … while (…)` directly as body, preserving
 *   the `do do x; while(a); while(b);` nested precedent
 *   (testDoWhileNested in HxDoWhileThrowTryCatchSliceTest).
 * - `ExprBody` — bare HxExpr with `@:trailOpt(';')`; the optional
 *   `;` covers both `do foo(); while(c);` (legacy) and
 *   `do $block while(c);` / `do a++ while(c);` (new sole-blockers).
 */
@:peg
enum HxDoWhileBody {
	@:fmt(leftCurly('blockLeftCurly'), emptyCurlyBreak('blockEmptyCurly'), rightCurly('blockRightCurly'), keepCurlyBlanks)
	@:lead('{') @:trail('}') @:trivia
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	BlockBody(stmts:Array<HxStatement>);

	@:kw('do') InnerDoWhile(inner:HxDoWhileStmt);

	@:trailOpt(';')
	ExprBody(expr:HxExpr);
}
