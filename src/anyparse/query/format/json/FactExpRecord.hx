package anyparse.query.format.json;

/** A macro expansion a facts file's node record holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactExpRecord = {
	final ?t: String;
	final p: Array<Int>;
	final a: Array<Int>;
	final ?d: Array<Int>;
}
