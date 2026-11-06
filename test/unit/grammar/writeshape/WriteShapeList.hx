package unit.grammar.writeshape;

/** A document whose root is an array: a struct written as its one field's value. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws @:bare
typedef WriteShapeList = {
	var items: Array<WriteShapeItem>;
}
