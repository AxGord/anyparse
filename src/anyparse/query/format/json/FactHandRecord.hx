package anyparse.query.format.json;

/** A hand-over a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactHandRecord = {
	final t: String;
	final s: String;
	final d: String;
	final p: Array<Int>;
}
