package dev;

/** A call and the size of its answer in tokens. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef BigCallRow = {
	var outTok: Int;
	var call: String;
}
