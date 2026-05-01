package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe enum declaration.
 *
 * Shape: `enum Name<TypeParams> { Ctor1; Ctor2; ... }` — structurally
 * identical to `HxClassDecl`: a keyword-introduced name with optional
 * declare-site type parameters followed by a close-peek Star field of
 * constructors inside braces.
 *
 * The `enum` keyword lives on the `name` field via `@:kw('enum')`
 * so the generated parser enforces a word boundary.
 *
 * `typeParams` is the symmetric close-peek-Star sibling of
 * `HxFnDecl.typeParams` — `HxTypeParamDecl` element type carrying
 * `name` and optional single-bound `constraint` (`<T:Foo>`).
 * Defaults and multi-bound syntax are deferred.
 *
 * Constructors with parameters are supported via `HxEnumCtor.ParamCtor`
 * which wraps `HxEnumCtorDecl` — see `HxEnumCtor`.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('ctors'))
typedef HxEnumDecl = {
	@:kw('enum') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:lead('{') @:trail('}') var ctors:Array<HxEnumCtor>;
}
