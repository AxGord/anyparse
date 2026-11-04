package anyparse.query.format.json;

/** A reflective call a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactReflRecord = {
	final t: String;
	final ?n: String;
	final ?m: String;
	final ?c: String;
	final ?v: Bool;
	final ?r: String;
	final ?x: Bool;
	final ?h: Bool;
	final ?o: Bool;
	final p: Array<Int>;
}
