package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe enum declaration.
 *
 * Shape: `enum Name { Ctor1; Ctor2; ... }` — structurally identical
 * to `HxClassDecl`: a keyword-introduced name followed by a
 * close-peek Star field of constructors inside braces.
 *
 * The `enum` keyword lives on the `name` field via `@:kw('enum')`
 * so the generated parser enforces a word boundary.
 *
 * Constructors with parameters are supported via `HxEnumCtor.ParamCtor`
 * which wraps `HxEnumCtorDecl` — see `HxEnumCtor`.
 */
@:peg
typedef HxEnumDecl = {
	@:kw('enum') var name:HxIdentLit;
	@:lead('{') @:trail('}') var ctors:Array<HxEnumCtor>;
}
