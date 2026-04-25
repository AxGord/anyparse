package anyparse.grammar.haxe;

/**
 * Catch clause grammar.
 *
 * Shape: `catch (name:Type) body`.
 *
 * The `catch` keyword and opening `(` are both on the `name` field —
 * `@:kw('catch')` emits `expectKw` and `@:lead('(')` emits
 * `expectLit`, both sequentially (D50). The closing `)` is
 * `@:trail(')')` on the `type` field. The `body` is a bare
 * `HxStatement` Ref — any statement branch (including `BlockStmt`)
 * is accepted.
 */
@:peg
typedef HxCatchClause = {
	@:kw('catch') @:lead('(') var name:HxIdentLit;
	@:lead(':') @:trail(')') var type:HxType;
	var body:HxStatement;
};
