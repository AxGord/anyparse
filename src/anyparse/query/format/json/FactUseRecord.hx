package anyparse.query.format.json;

/** How a read's value is used, as a field record and a parameter's use record spell it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactUseRecord = {
	var ?u: String;
	var ?m: String;
	var ?ag: String;
	var ?aa: String;
	var ?ai: Int;
}
