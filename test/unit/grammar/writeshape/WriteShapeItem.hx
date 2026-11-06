package unit.grammar.writeshape;

/** The nested record of the write-shape fixtures. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef WriteShapeItem = {
	var n: Int;
	var tags: Array<String>;
}
