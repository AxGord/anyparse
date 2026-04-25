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
 * The `type` field is a full `HxType`, so struct typedefs
 * (`typedef Foo = {a:Int, b:String}`) and function types (`typedef
 * Foo = Int->Void`) compose through `HxType.Anon` and `HxType.Arrow`.
 * The writer-side `=` spacing for typedef rhs is governed by the
 * `@:lead('=')` literal emission and remains tight pending an
 * assignment-style knob (compare `HxVarDecl.init` which produces
 * ` = ` via the surrounding context).
 */
@:peg
typedef HxTypedefDecl = {
	@:kw('typedef') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') var typeParams:Null<Array<HxIdentLit>>;
	@:lead('=') var type:HxType;
}
