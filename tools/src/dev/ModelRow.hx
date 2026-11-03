package dev;

/** The usage of one model summed over every agent, and what it costs at `PRICES`. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef ModelRow = {
	var model: String;
	var turns: Int;
	var input: Int;
	var output: Int;
	var cacheRead: Int;
	var cacheWrite: Int;
	var cost: Float;
}
