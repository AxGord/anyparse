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
 *
 * `@:fmt(bodyAllmanIndentForCtor('ObjectLit', 'indentObjectLiteral'))`
 * on `body` — structural runtime override that fires when ALL apply:
 * body's runtime ctor is `ObjectLit`, the body's writeCall has
 * internal hardlines (`flatLength == -1`), and `opt.indentObjectLiteral`
 * is true. Layout becomes `_dn(_cols, [_dhl(), _dn(_cols, body)])` —
 * `{` on its own line at +cols, fields at +2cols, `}` at +cols —
 * regardless of the policy axis (Same/Next/FitLine/Keep) AND
 * regardless of `opt.objectLiteralLeftCurly` (which controls obj-lit
 * placement in RHS-value contexts like `var x = {...}` where fork
 * keeps `{` cuddled). The for-comprehension body breaks the obj-lit
 * out structurally per fork's rule for `[for (x in xs) {<multi>}]`.
 * Single-line obj-lit bodies, non-ObjectLit values, or
 * `indentObjectLiteral=false` configs fall through. The asymmetry
 * vs `HxIfExpr.thenBranch` (which stays cuddled for
 * `if (cond) {<obj>}`) is intentional and matches fork's per-
 * construct rule (verified via fork CLI probe).
 */
@:peg
typedef HxForExpr = {
	@:lead('(') var varName:HxIdentLit;
	@:kw('in') @:trail(')') var iterable:HxExpr;
	@:fmt(bodyPolicy('expressionForBody'), bodyAllmanIndentForCtor('ObjectLit', 'indentObjectLiteral')) var body:HxExpr;
};
