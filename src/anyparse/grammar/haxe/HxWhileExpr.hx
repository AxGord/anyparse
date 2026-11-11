package anyparse.grammar.haxe;

/**
 * Expression-position `while` loop — the head of a Haxe array
 * comprehension (`[while (cond) bodyExpr]`) or any value-position
 * while-loop where the body produces a value.
 *
 * Mirror of `HxWhileStmt` with `body:HxExpr` instead of `body:HxStatement`.
 * Statement-level `while` still dispatches through
 * `HxStatement.WhileStmt(HxWhileStmt)` via source-order priority — at
 * statement position the `while` keyword is consumed there before the
 * expression parser looks at it. The dual-typedef split mirrors
 * `HxForStmt`/`HxForExpr` (and `HxIfStmt`/`HxIfExpr` before that).
 *
 * `body` carries the `HxForExpr.body` flags: a `while` comprehension is laid
 * out like a `for` one, so a body that does not fit beside the head moves to
 * the next line before the head's own condition call wraps, under the one
 * comprehension knob `expressionForBody`. `HxForExpr`'s doc carries each flag's contract.
 */
@:peg
typedef HxWhileExpr = {
	@:lead('(')
	@:trail(')')
	var cond: HxExpr;
	@:fmt(bodyPolicy('expressionForBody'), bodyAllmanIndentForCtor('ObjectLit', 'indentObjectLiteral', 'comprehensionObjectLitGlue'),
		reflowCtorOnFitLine('expressionForBody', 'ObjectLit', 'ParenExpr'),
		strictFitLineBody('IfExpr', 'ForExpr', 'ForReifExpr', 'WhileExpr'))
	var body: HxExpr;
};
