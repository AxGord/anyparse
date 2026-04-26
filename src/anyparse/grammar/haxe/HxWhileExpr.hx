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
 * No `@:fmt(bodyPolicy(...))` on `body` — array-comprehension bodies
 * almost always fit on one line in practice (`[while (cond) v]`).
 * If corpus evidence later shows a multi-line policy is needed, wire
 * the `bodyPolicy` knob the same way `HxWhileStmt` does. Same
 * precedent as `HxForExpr` and `HxIfExpr` skipping the body wrap
 * knobs that their statement-level counterparts carry.
 */
@:peg
typedef HxWhileExpr = {
	@:lead('(') @:trail(')') var cond:HxExpr;
	var body:HxExpr;
};
