package anyparse.query.format.json;

/** A string conversion a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactStrRecord = {
	final o: String;
	final p: Array<Int>;
	final ?x: Bool;
}
