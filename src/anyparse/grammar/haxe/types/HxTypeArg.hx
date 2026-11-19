package anyparse.grammar.haxe.types;

/**
 * Type-parameter value element — the dedicated element type of `HxTypeRef.params` (see `HxTypeRef.hx` for the
 * param-list mechanics: open `<` / sep `,` / close `>`). It wraps one `HxType`, so the element is a query type slot of
 * its own and its type is written as a nested one; an intersection (`EitherType<A, B & C>`) is that type's own
 * `HxType.Intersection`. Consumers reach the type via `.type`.
 */
@:peg
typedef HxTypeArg = {

	@:queryType
	@:fmt(propagateNestedType)
	var type: HxType;

}
