package anyparse.query.format.json;

/** A value flow a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactFlowRecord = {
	final s: String;
	final d: String;
	final c: String;
	final p: Array<Int>;
	final ?x: Bool;
}
