package anyparse.query.format.json;

/** A local variable a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactVarRecord = {
	final n: String;
	final t: String;
	final p: Array<Int>;
}
