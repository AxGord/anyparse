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
 * `@:fmt(bodyPolicy('expressionForBody'))` on `body` — distinct from
 * `HxForStmt`'s `forBody` knob because expression-position `for`
 * (array comprehensions, value-position) needs different default
 * behaviour. Default `Keep` preserves source layout via the
 * `<field>BeforeNewline:Bool` synth slot; matches haxe-formatter's
 * `sameLine.expressionIf: @:default(Keep)`. Setting the JSON key
 * `sameLine.expressionIf` overrides all three expression-knob
 * defaults uniformly. Single-line bodies under any policy stay flat
 * — `[for (i in 0...10) i * i]` is unaffected.
 */
@:peg
typedef HxForExpr = {
	@:lead('(') var varName:HxIdentLit;
	@:kw('in') @:trail(')') var iterable:HxExpr;
	@:fmt(bodyPolicy('expressionForBody')) var body:HxExpr;
};
