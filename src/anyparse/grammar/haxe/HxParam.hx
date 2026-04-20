package anyparse.grammar.haxe;

/**
 * A single function parameter in a Haxe function declaration.
 *
 * Shape: `name : Type` or `name : Type = defaultValue`.
 *
 * The type annotation is mandatory (same as `HxVarDecl`). The default
 * value is optional, using the same `@:optional @:lead('=')` pattern
 * as `HxVarDecl.init` — `matchLit` peeks the `=` as a commit point,
 * and the full `HxExpr` sub-rule fires only on hit.
 *
 * Varargs (`...`), type parameters on parameter types, and `?param`
 * optional-parameter syntax are deferred.
 */
@:peg
typedef HxParam = {
	var name:HxIdentLit;
	@:fmt(typeHintColon) @:lead(':') var type:HxTypeRef;
	@:optional @:lead('=') var defaultValue:Null<HxExpr>;
}
