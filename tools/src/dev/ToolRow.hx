package dev;

/** One kind of tool call summed over every agent; sizes in tokens. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef ToolRow = {
	var key: String;
	var calls: Int;
	var outTok: Int;
	var avgOutTok: Int;
	var inTok: Int;
	var over2k: Int;
	var over5k: Int;
}
