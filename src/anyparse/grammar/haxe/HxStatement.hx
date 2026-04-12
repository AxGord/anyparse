package anyparse.grammar.haxe;

/**
 * Statement grammar for Haxe function bodies.
 *
 * Three branches in source order — keyword-dispatched branches first,
 * expression-statement catch-all last:
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
 *  - `ExprStmt` — `expr;` expression-statement. Catch-all: any
 *    expression followed by a semicolon. Must appear last because it
 *    has no keyword guard — if placed before the keyword branches,
 *    input like `return 1;` would attempt to parse `return` as an
 *    `IdentExpr` atom.
 *
 * All three branches are Case 3 in `Lowering.lowerEnumBranch`
 * (single-Ref with optional kw lead + optional trail). No new macro
 * concepts.
 */
@:peg
enum HxStatement {
	@:kw('var') @:trail(';')
	VarStmt(decl:HxVarDecl);

	@:kw('return') @:trail(';')
	ReturnStmt(value:HxExpr);

	@:trail(';')
	ExprStmt(expr:HxExpr);
}
