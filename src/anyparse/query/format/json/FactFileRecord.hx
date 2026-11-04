package anyparse.query.format.json;

/** A file a dump's positions name by index (`{"k":"file",…}`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactFileRecord = {
	final i: Int;
	final path: String;
}
