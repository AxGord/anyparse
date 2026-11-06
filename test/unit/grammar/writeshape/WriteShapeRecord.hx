package unit.grammar.writeshape;

/** A record of every field form a writer spells beyond its value: a held null kept or left out, a float, empty and nested containers. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef WriteShapeRecord = {
	var name: String;
	@:optional @:writeNull var note: Null<String>;
	@:optional var skip: Null<Int>;
	var ratio: Float;
	@:optional @:writeNull var whole: Null<Float>;
	var items: Array<WriteShapeItem>;
	var empty: Array<Int>;
	@:optional @:writeNull var inner: Null<WriteShapeItem>;
}
