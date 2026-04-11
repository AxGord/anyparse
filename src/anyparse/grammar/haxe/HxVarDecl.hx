package anyparse.grammar.haxe;

/**
 * Variable declaration body for a class member `var`.
 *
 * Phase 3 slice: name plus a type annotation prefixed by `:`. Initializer
 * expressions, modifiers (`public`, `private`, `static`, …), property
 * accessors (`(default, null)`), and default values are all out of
 * scope for this session.
 *
 * The `var` keyword itself and the trailing `;` live on the enclosing
 * `HxClassMember.VarMember` constructor via `@:kw` / `@:trail` — this
 * typedef only describes the inside.
 */
@:peg
typedef HxVarDecl = {
	var name:HxIdentLit;
	@:lead(':') var type:HxTypeRef;
}
