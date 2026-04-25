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
 * `HxFnDecl.typeParams` — `HxTypeParamDecl` element type carrying
 * `name` and optional single-bound `constraint` (`<T:Foo>`).
 * Defaults and multi-bound syntax are deferred.
 *
 * The trailing semicolon lives on the `TypedefDecl` branch in
 * `HxDecl` via `@:trail(';')`, not here — this typedef only
 * describes the inside, matching the pattern used by `HxVarDecl`
 * and `HxFnDecl`.
 *
 * The `type` field is a full `HxType`, so struct typedefs
 * (`typedef Foo = {a:Int, b:String}`) and function types (`typedef
 * Foo = Int->Void`) compose through `HxType.Anon` and `HxType.Arrow`.
 * Writer-side `=` spacing on the rhs is driven by `@:fmt(typedefAssign)`
 * (slice ω-typedef-assign): default `WhitespacePolicy.Both` emits
 * `typedef Foo = Bar;` matching haxe-formatter's
 * `whitespace.binopPolicy: @:default(Around)`. Setting
 * `typedefAssign: WhitespacePolicy.None` reverts to the pre-slice
 * tight layout (`typedef Foo=Bar;`). The optional-Ref `=` leads on
 * `HxVarDecl.init` and `HxParam.defaultValue` still flow through the
 * bare-optional fallback path, which already emits ` = `.
 */
@:peg
typedef HxTypedefDecl = {
	@:kw('typedef') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:fmt(typedefAssign) @:lead('=') var type:HxType;
}
