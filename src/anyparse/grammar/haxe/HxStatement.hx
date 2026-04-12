package anyparse.grammar.haxe;

/**
 * Statement grammar for Haxe function bodies.
 *
 * Eight branches in source order — keyword-dispatched branches first,
 * block statement next, expression-statement catch-all last:
 *
 *  - `VarStmt` — `var name:Type = init;` local variable declaration.
 *    Reuses `HxVarDecl` from the class-member grammar. The `var`
 *    keyword is consumed here (not in `HxVarDecl` itself, which is
 *    a plain typedef). The trailing `;` is consumed by the branch's
 *    `@:trail`.
 *
 *  - `ReturnStmt` — `return expr;` return statement with a value.
 *    Tried before `VoidReturnStmt` — if expression parsing fails
 *    (e.g. next token is `;`), tryBranch rolls back and the void
 *    variant is tried.
 *
 *  - `VoidReturnStmt` — `return;` void return statement. Zero-arg
 *    ctor with `@:kw('return') @:trail(';')`. Lowering Case 0
 *    extended to emit the trail literal (D48).
 *
 *  - `IfStmt` — `if (cond) body [else body]`. Dispatched by the
 *    `if` keyword. The body is parsed via `HxIfStmt` typedef which
 *    handles parenthesised condition, then-body, and optional else.
 *
 *  - `WhileStmt` — `while (cond) body`. Dispatched by the `while`
 *    keyword. The body is parsed via `HxWhileStmt` typedef which
 *    handles parenthesised condition and body.
 *
 *  - `ForStmt` — `for (varName in iterable) body`. Dispatched by
 *    the `for` keyword. The body is parsed via `HxForStmt` typedef
 *    which handles the parenthesised `varName in iterable` clause
 *    and the loop body.
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

	@:kw('return') @:trail(';')
	VoidReturnStmt;

	@:kw('if')
	IfStmt(stmt:HxIfStmt);

	@:kw('while')
	WhileStmt(stmt:HxWhileStmt);

	@:kw('for')
	ForStmt(stmt:HxForStmt);

	@:lead('{') @:trail('}')
	BlockStmt(stmts:Array<HxStatement>);

	@:trail(';')
	ExprStmt(expr:HxExpr);
}
