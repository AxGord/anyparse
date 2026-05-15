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
 *
 * Each entry is an `HxEnumMember` (leading-metadata Star + `HxEnumCtor`)
 * so `@:meta`-annotated constructors round-trip — the enum-body analog
 * of `HxType.Anon` iterating `HxAnonMember`. The no-metadata case is
 * transparent: an empty `meta` Star leaves the close-peek Star and the
 * per-branch `@:trail(';')` behaving exactly as the bare `HxEnumCtor`
 * form did.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('ctors'))
typedef HxEnumDecl = {
	@:kw('enum') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:fmt(beginEndType, existingBetweenFields, uniformBetween('betweenEnumCtors'), beforeDocCommentEmptyLines) @:lead('{') @:trail('}') @:trivia var ctors:Array<HxEnumMember>;
}
