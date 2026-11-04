package anyparse.query.format.json;

/** A generic instantiation a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactGenRecord = {
	final d: String;
	final s: String;
	final p: Array<Int>;
}
