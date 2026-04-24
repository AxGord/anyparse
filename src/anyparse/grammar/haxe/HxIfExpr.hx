package anyparse.grammar.haxe;

/**
 * Expression-position `if` — `if (cond) thenBranch [else elseBranch]`
 * used where a value is expected (object-literal field, call argument,
 * RHS of assignment, array element, etc.).
 *
 * Structurally parallel to `HxIfStmt` but both branches are `HxExpr`,
 * not `HxStatement` — no trailing `;`, no block-statement fallthrough.
 * The statement-level construct still dispatches through
 * `HxStatement.IfStmt(HxIfStmt)` because enum-branch source order puts
 * `IfStmt` ahead of `ExprStmt` in `HxStatement` — the `if` keyword is
 * consumed by the statement branch before the expression parser ever
 * looks at it.
 *
 * Dangling-else follows the same rule as `HxIfStmt`: the nearest
 * enclosing `if` greedily consumes the next `else`, so
 * `if (a) if (b) x else y` binds `else y` to the inner `if`.
 *
 * No `@:fmt` knobs for now — expression-if almost always fits on one
 * line in practice (object-literal field values, call arguments). If
 * corpus evidence later shows a multi-line policy is needed, wire the
 * bodyPolicy / sameLine / fitLineIfWithElse knobs the same way
 * `HxIfStmt` does.
 */
@:peg
typedef HxIfExpr = {
	@:lead('(') @:trail(')') var cond:HxExpr;
	var thenBranch:HxExpr;
	@:optional @:kw('else') var elseBranch:Null<HxExpr>;
};
