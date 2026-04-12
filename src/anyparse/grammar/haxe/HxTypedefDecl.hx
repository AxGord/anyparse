package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe typedef declaration.
 *
 * Shape: `typedef Name = TypeRef` — a type alias binding a name to
 * a type reference. The `typedef` keyword lives on the `name` field
 * via `@:kw('typedef')` so the generated parser enforces a word
 * boundary (`typedefine` is rejected).
 *
 * The trailing semicolon lives on the `TypedefDecl` branch in
 * `HxDecl` via `@:trail(';')`, not here — this typedef only
 * describes the inside, matching the pattern used by `HxVarDecl`
 * and `HxFnDecl`.
 *
 * Struct typedefs (`typedef Foo = { ... }`) and function types
 * (`typedef Foo = Int -> Void`) are deferred — `HxTypeRef` is
 * currently a single identifier.
 */
@:peg
typedef HxTypedefDecl = {
	@:kw('typedef') var name:HxIdentLit;
	@:lead('=') var type:HxTypeRef;
}
