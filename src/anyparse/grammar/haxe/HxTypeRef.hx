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
 * `params` carries `Array<HxType>` (not `Array<HxTypeRef>`) so type
 * parameters compose with the full Alt — once arrow / anon-struct
 * variants land, `Array<Int -> Void>` and `Map<{a:Int}, B>` parse
 * naturally without revisiting the element type.
 */
@:peg
typedef HxTypeRef = {
	var name:HxTypeName;
	@:optional @:lead('<') @:trail('>') @:sep(',') var params:Null<Array<HxType>>;
}
