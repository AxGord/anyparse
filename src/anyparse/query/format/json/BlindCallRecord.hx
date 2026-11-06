package anyparse.query.format.json;

/** A call the graph resolves to nothing, as a blind long-lock reason writes it: its name and position. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef BlindCallRecord = {

	var name: String;

	var line: Int;

	var col: Int;
};
