package anyparse.grammar.haxe;

/**
 * Statement grammar for Haxe function bodies.
 *
 * Six branches in source order — keyword-dispatched branches first,
 * block statement next, expression-statement catch-all last:
 *
 *  - `VarStmt` — `var name:Type = init;` local variable declaration.
 *    Reuses `HxVarDecl` from the class-member grammar. The `var`
 *    keyword is consumed here (not in `HxVarDecl` itself, which is
 *    a plain typedef). The trailing `;` is consumed by the branch's
 *    `@:trail`.
 *
 *  - `ReturnStmt` — `return expr;` return statement. Expression is
 *    mandatory in this slice; void `return;` is a future extension
 *    requiring `@:optional` on the value field.
 *
 *  - `IfStmt` — `if (cond) body [else body]`. Dispatched by the
 *    `if` keyword. The body is parsed via `HxIfStmt` typedef which
 *    handles parenthesised condition, then-body, and optional else.
 *
 *  - `WhileStmt` — `while (cond) body`. Dispatched by the `while`
 *    keyword. The body is parsed via `HxWhileStmt` typedef which
 *    handles parenthesised condition and body.
 *
 *  - `BlockStmt` — `{ stmts }` block statement. No keyword guard —
 *    dispatched by the `{` literal. Uses Case 4 in
 *    `Lowering.lowerEnumBranch` (Array<Ref> with lead/trail, no sep).
 *    Must appear before `ExprStmt` so the `{` is not consumed by the
 *    expression parser.
 *
 *  - `ExprStmt` — `expr;` expression-statement. Catch-all: any
 *    expression followed by a semicolon. Must appear last because it
 *    has no keyword guard — if placed before the keyword branches,
 *    input like `return 1;` would attempt to parse `return` as an
 *    `IdentExpr` atom.
 */
@:peg
enum HxStatement {
	@:kw('var') @:trail(';')
	VarStmt(decl:HxVarDecl);

	@:kw('return') @:trail(';')
	ReturnStmt(value:HxExpr);

	@:kw('if')
	IfStmt(stmt:HxIfStmt);

	@:kw('while')
	WhileStmt(stmt:HxWhileStmt);

	@:lead('{') @:trail('}')
	BlockStmt(stmts:Array<HxStatement>);

	@:trail(';')
	ExprStmt(expr:HxExpr);
}
