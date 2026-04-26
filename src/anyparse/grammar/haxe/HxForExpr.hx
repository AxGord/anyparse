package anyparse.grammar.haxe;

/**
 * Expression-position `for` loop — the head of a Haxe array
 * comprehension (`[for (x in xs) bodyExpr]`) or any value-position
 * for-loop where the body produces a value.
 *
 * Structurally parallel to `HxForStmt` but `body` is `HxExpr`, not
 * `HxStatement` — array-comprehension bodies must be value-producing
 * expressions. Nested comprehensions like
 * `[for (a in xs) for (b in ys) a * b]` work naturally because the
 * inner `for` is itself an `HxExpr` (`ForExpr`), so `body:HxExpr`
 * accepts it without a separate sentinel branch.
 *
 * The statement-level form still dispatches through
 * `HxStatement.ForStmt(HxForStmt)` because enum-branch source order
 * puts `ForStmt` ahead of `ExprStmt` in `HxStatement` — at statement
 * position the `for` keyword is consumed by the statement branch
 * before the expression parser ever looks at it. The dual-typedef
 * split (`HxForStmt` vs `HxForExpr`) mirrors the existing
 * `HxIfStmt`/`HxIfExpr` precedent: same source shape, different
 * body type.
 *
 * Map-key iteration `for (k => v in m)` is not yet supported — the
 * `varName:HxIdentLit` field shape mirrors `HxForStmt`'s current
 * limitation. Lifting requires a destructured-iter shape on both
 * forms, tracked as a future slice.
 *
 * No `@:fmt(bodyPolicy(...))` on `body` — array-comprehension bodies
 * almost always fit on one line in practice (`[for (x in xs) f(x)]`,
 * `[for (i in 0...10) i * i]`). If corpus evidence later shows a
 * multi-line policy is needed, wire the `bodyPolicy` knob the same
 * way `HxForStmt` does. Same precedent as `HxIfExpr` skipping the
 * if-body wrap knobs that `HxIfStmt` carries.
 */
@:peg
typedef HxForExpr = {
	@:lead('(') var varName:HxIdentLit;
	@:kw('in') @:trail(')') var iterable:HxExpr;
	var body:HxExpr;
};
