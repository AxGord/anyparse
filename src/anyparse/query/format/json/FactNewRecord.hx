package anyparse.query.format.json;

/** A construction a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactNewRecord = {
	final t: String;
	final ty: String;
	final p: Array<Int>;
	final ?gb: String;
}
