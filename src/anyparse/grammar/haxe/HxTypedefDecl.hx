package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe typedef declaration.
 *
 * Shape: `typedef Name<TypeParams> = TypeRef` — a type alias binding
 * a name (with optional declare-site type parameters) to a type
 * reference. The `typedef` keyword lives on the `name` field via
 * `@:kw('typedef')` so the generated parser enforces a word boundary
 * (`typedefine` is rejected).
 *
 * `typeParams` is the symmetric close-peek-Star sibling of
 * `HxFnDecl.typeParams` — bare-identifier declare-site form.
 * Constraints/defaults are deferred.
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
	@:optional @:lead('<') @:trail('>') @:sep(',') var typeParams:Null<Array<HxIdentLit>>;
	@:lead('=') var type:HxTypeRef;
}
