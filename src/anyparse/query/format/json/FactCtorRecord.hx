package anyparse.query.format.json;

/** An enum constructor a facts file's type record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactCtorRecord = {
	final n: String;
	final t: String;
}
