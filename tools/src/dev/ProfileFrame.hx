package dev;

/** The call frame of a V8 CPU profile node. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ProfileFrame = {
	@:optional var functionName: String;
	@:optional var url: String;
	@:optional var lineNumber: Int;
};
