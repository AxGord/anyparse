package anyparse.query.format.json;

/** An iteration a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactIterRecord = {
	final v: String;
	final i: String;
	final p: Array<Int>;
}
