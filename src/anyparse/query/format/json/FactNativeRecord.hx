package anyparse.query.format.json;

/** A native call a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactNativeRecord = {
	final w: String;
	final n: String;
	final p: Array<Int>;
	final ?c: String;
	final ?cc: Bool;
	final ?h: Array<String>;
}
