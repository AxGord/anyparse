package anyparse.query.format.json;

/** A parameter of a facts file's node record. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactParamRecord = {
	final n: String;
	final t: String;
}
