package anyparse.grammar.haxe;

/**
 * While-loop grammar.
 *
 * Structure: `while (cond) body`.
 *
 * The condition is wrapped in mandatory parentheses. The body is a bare
 * `HxStatement` Ref field — any statement branch (including
 * `BlockStmt`) is accepted. Uses only existing Lowering patterns:
 * `@:lead` / `@:trail` on a Ref field and a bare Ref field.
 */
@:peg
typedef HxWhileStmt = {
	@:lead('(') @:trail(')') var cond:HxExpr;
	@:bodyPolicy('whileBody') var body:HxStatement;
};
