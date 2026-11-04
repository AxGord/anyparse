package anyparse.query.format.json;

/** An element write a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactElemRecord = {
	final r: String;
	final rp: Array<Int>;
	final p: Array<Int>;
}
