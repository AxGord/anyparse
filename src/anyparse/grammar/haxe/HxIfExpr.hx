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
 * `@:fmt(bodyPolicy('expressionIfBody'))` on `thenBranch` and
 * `@:fmt(bodyPolicy('expressionElseBody'))` on `elseBranch` — distinct
 * from `HxIfStmt`'s `ifBody` / `elseBody` knobs because expression-
 * position `if` needs different default behaviour. Default `Keep`
 * preserves source layout via the `<field>BeforeNewline:Bool` synth
 * slot (then-branch via the bare-Ref non-first synth, else-branch via
 * the existing optional-kw `BodyOnSameLine` synth). Matches haxe-
 * formatter's `sameLine.expressionIf: @:default(Keep)`. The single
 * JSON key `sameLine.expressionIf` fans out into all three expression
 * body knobs at load time. Single-line branches under any policy
 * stay flat — short flat-fitting expression-`if` (object field
 * values, call args) is unaffected.
 *
 * `elseBranch` does NOT carry the statement-level `sameLine` /
 * `shapeAware` / `elseIf` / `fitLineIfWithElse` companions: those
 * knobs trigger Allman-style placement and policy interactions
 * tuned for statement-`if`. Expression-`if` always reads as one
 * value, and `else if` chains in expression position are handled
 * naturally by recursion through `HxIfExpr.elseBranch:Null<HxExpr>`
 * being itself an `IfExpr`.
 */
@:peg
typedef HxIfExpr = {
	@:lead('(') @:trail(')') var cond:HxExpr;
	@:fmt(bodyPolicy('expressionIfBody')) var thenBranch:HxExpr;
	@:optional @:kw('else') @:fmt(bodyPolicy('expressionElseBody')) var elseBranch:Null<HxExpr>;
};
