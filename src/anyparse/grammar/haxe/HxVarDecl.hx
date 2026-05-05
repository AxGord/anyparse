package anyparse.grammar.haxe;

/**
 * Variable declaration body for a class member `var`.
 *
 * Phase 3 slice: name, an optional type annotation prefixed by `:`,
 * and an optional initializer prefixed by `=`. Either, both, or neither
 * may be present — `var x;`, `var x:Int;`, `var x = 1;`, `var x:Int = 1;`
 * all parse. The initializer, when present, is a single `HxExpr` atom
 * (int / bool / null / identifier) — operators, calls, and field access
 * come with the Pratt slice.
 *
 * Modifiers (`public`, `private`, `static`, …), property accessors
 * (`(default, null)`), and default values are out of scope for this
 * session.
 *
 * The `var` keyword itself and the trailing `;` live on the enclosing
 * `HxClassMember.VarMember` constructor via `@:kw` / `@:trail` — this
 * typedef only describes the inside.
 *
 * The `init` field is marked both `@:optional` and `Null<HxExpr>`:
 * both axes are required by `ShapeBuilder` so the grammar source
 * documents optionality without forcing a reader to cross-reference
 * the type and the meta list (D23). The `@:lead('=')` is the commit
 * point for the optional — `matchLit` peeks it, and the sub-rule
 * parse only fires when the peek hits (D24).
 *
 * `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 * 'objectLiteralLeftCurly'))` (slice ω-indent-objectliteral) wraps the
 * writer call for `init` in a runtime gate that — when the bound
 * `HxExpr` ctor is `ObjectLit` AND `opt.indentObjectLiteral` is true
 * (default) AND `opt.objectLiteralLeftCurly` is `Next` (`{` on its own
 * line) — applies a `Nest(_cols, …)` wrap so the value's hardlines
 * pick up one extra indent step. Visible effect under Allman:
 * `var x =\n\t{...}` instead of `var x =\n{...}`, matching haxe-
 * formatter's `indentation.indentObjectLiteral` rule which only fires
 * when `{` lands on its own line. Cuddled `Same` placement is
 * unchanged — the gate is inert because `{` already sits on the parent
 * line.
 *
 * A second `@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`
 * entry (slice ω-indent-complex-value-expr) stacks on the same field —
 * when the bound `HxExpr` ctor is `IfExpr` AND
 * `opt.indentComplexValueExpressions` is true (non-default), a
 * `Nest(_cols, …)` wrap shifts the if-expression's block bodies one
 * indent step right (`var x = if (cond) {\n\t\t…\n\t};` instead of
 * `var x = if (cond) {\n\t…\n};`). Mirrors haxe-formatter's
 * `indentation.indentComplexValueExpressions` rule. The 2-arg form
 * drops the leftCurly gate — `if` always cuddles its `{`, so a
 * placement check would be inert. Other RHS ctors (calls, binops,
 * literals other than ObjectLit/IfExpr) are unaffected.
 */
@:peg
typedef HxVarDecl = {
	var name:HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type:Null<HxType>;
	@:optional
	@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'),
		indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))
	@:lead('=') var init:Null<HxExpr>;
}
