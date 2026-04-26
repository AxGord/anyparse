package anyparse.grammar.haxe;

/**
 * Catch clause grammar (block-body form).
 *
 * Shape: `catch (name:Type) body`.
 *
 * The `catch` keyword and opening `(` are both on the `name` field —
 * `@:kw('catch')` emits `expectKw` and `@:lead('(')` emits
 * `expectLit`, both sequentially (D50). The closing `)` is
 * `@:trail(')')` on the `type` field. The `body` is a bare
 * `HxStatement` Ref — any statement branch (including `BlockStmt`)
 * is accepted. The bare-expression sibling `HxCatchClauseStmtBare`
 * carries the same name/type fields with `body:HxExpr`.
 */
@:peg
typedef HxCatchClause = {
	@:kw('catch') @:lead('(') var name:HxIdentLit;
	@:lead(':') @:trail(')') var type:HxType;
	var body:HxStatement;
};
