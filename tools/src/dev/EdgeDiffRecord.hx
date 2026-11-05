package dev;

/** One line of the `edge-diff` output: a function and the edges its syntax graph and its typed graph hold. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef EdgeDiffRecord = {
	var id: String;
	@:optional var file: String;
	var syntax: Array<String>;
	var facts: Array<String>;
};
