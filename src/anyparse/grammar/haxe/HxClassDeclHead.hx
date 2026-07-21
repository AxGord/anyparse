package anyparse.grammar.haxe;

/**
 * A `class` declaration's header WITHOUT its body: the `class` keyword,
 * the name, optional type parameters and the heritage clauses - every
 * field of `HxClassDecl` except `members`, which owns the `{ ... }`.
 *
 * Exists solely for `HxCondSharedBodyDecl`, where the header sits inside
 * a conditional region and the body after it (see that type for the
 * shape and the rejected alternatives). Splitting the header off is what
 * lets the FIRST branch of such a region stay structural - the name,
 * type parameters and heritage all remain queryable - while the parallel
 * headers ride a raw byte capture.
 *
 * The fields are copied from `HxClassDecl` verbatim, `@:fmt` flags
 * included, rather than factored into a shared base: a `@:peg` typedef
 * is flattened field-by-field by the codegen, and FIELD POSITION is
 * load-bearing for the writer's trivia slots, so introducing an
 * indirection into `HxClassDecl` to share three fields would move every
 * existing class declaration's slots. Duplication here is the cheaper
 * side of that trade - `HxClassDecl` is left byte-identical.
 *
 * The opening `{` is NOT part of this type. It is consumed by the
 * `@:trail('{')` on `HxDeclHead.ClassHead`, so the same header type
 * could serve a future production that does not open a body at all.
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef HxClassDeclHead = {
	@:kw('class') var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:trivia @:tryparse @:fmt(padLeading, lineLengthAwareSeps, heritageWrap) var heritage: Array<HxHeritageClause>;
}
