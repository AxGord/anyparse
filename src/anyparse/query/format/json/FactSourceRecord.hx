package anyparse.query.format.json;

/** A source file a compile read, with the hash of its text (`{"k":"src",…}`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactSourceRecord = {
	final path: String;
	final len: Int;
	final md5: String;
	final ?changed: Bool;
}
