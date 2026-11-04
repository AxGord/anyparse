package anyparse.query.format.json;

/** A call a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactCallRecord = {
	final ?t: String;
	final a: String;
	final ?r: String;
	final ?rp: Array<Int>;
	final rt: String;
	final ?sig: String;
	final p: Array<Int>;
	final ?s: Array<Int>;
	final ?d: Array<Int>;
	final ?o: String;
	final ?x: Bool;
}
