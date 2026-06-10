package anyparse.grammar.haxe;

/**
 * Named-type reference in the Haxe grammar.
 *
 * Carries a possibly module-qualified name with an optional
 * angle-bracketed type-parameter list — enough to cover `Int`,
 * `Array<Int>`, `Map<String, Int>`, `Foo<Bar<Baz>>`, sub-module forms
 * (`Module.SubType`), and pack-qualified forms (`haxe.io.Bytes`).
 *
 * `HxTypeRef` is a leaf alongside the wider `HxType` Alt (the named-
 * type variant). Function types (`Int -> Void`) and anonymous
 * structure types live as additional `HxType` branches; this typedef
 * stays focused on the named form.
 *
 * The `name` field is `HxTypeName`, a terminal that matches a dotted
 * identifier sequence as one regex slice — keeping the type-ref shape
 * flat at the cost of forfeiting structured access to individual pack
 * segments. A future analysis pass can split on `.` if needed.
 *
 * `params` carries `Array<HxTypeArg>` (not `Array<HxType>`): each
 * element is an `HxType` with an optional structural-intersection tail
 * (`A & B & C` inside `EitherType<…, A & B & C>`). The wrapper exists
 * so intersection composes at the type-arg position without adding `&`
 * to the general `HxType` Pratt op set (see `HxTypeArg` doc). The Alt
 * composes normally inside the wrapper — `Array<Int -> Void>` and
 * `Map<{a:Int}, B>` parse via the `.type` field; the empty-intersection
 * case yields `.intersections == []` and the writer emits nothing
 * extra.
 */
@:peg
typedef HxTypeRef = {
	var name: HxTypeName;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var params: Null<Array<HxTypeArg>>;
}
