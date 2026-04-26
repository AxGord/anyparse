package anyparse.grammar.haxe;

/**
 * Switch grammar with a bare (no-parens) subject expression.
 *
 * Shape: `switch expr { case ...: ... default: ... }` — identical
 * to `HxSwitchStmt` except the subject is a plain `HxExpr` instead
 * of a parenthesised one. `Array<HxSwitchCase>` is reused as-is —
 * case shape does not depend on whether the subject had parens.
 *
 * The `switch` keyword is consumed at the enum-branch level
 * (`@:kw('switch')` on `HxStatement.SwitchStmtBare` and
 * `HxExpr.SwitchExprBare`). Source-order in those enums tries the
 * parens-form first via `tryBranch`; when its `@:lead('(')` fails
 * (or the inner parens-form parse fails further in — e.g.
 * `switch (x).y { … }` where the next token after `(x)` is `.`
 * not `)`), the parser rolls back the `switch` keyword and `(`
 * consumption and tries this bare form next. Same paired-ctor
 * precedent as `HxStatement.TryCatchStmt` / `TryCatchStmtBare`.
 *
 * The subject's Pratt loop terminates cleanly on `{` because the
 * left brace is not an infix operator in `HxExpr` — it is only an
 * atom prefix (`BlockExpr` / `ObjectLit`).
 */
@:peg
typedef HxSwitchStmtBare = {
	var expr:HxExpr;
	@:lead('{') @:trail('}') @:trivia var cases:Array<HxSwitchCase>;
};
