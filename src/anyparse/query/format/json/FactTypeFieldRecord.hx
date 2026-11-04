package anyparse.query.format.json;

/** A field a facts file's type record declares. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactTypeFieldRecord = {
	final n: String;
	final k: String;
	final t: String;
	final ?s: Bool;
	final ?meta: Array<String>;
	final ?code: Array<Null<String>>;
	final ?over: Int;
}
