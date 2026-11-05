package devkit;

/** One count a branch read, by its name. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef Reading = {
	var name: String;
	var value: Int;
};
