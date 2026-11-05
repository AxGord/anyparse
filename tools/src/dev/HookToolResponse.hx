package dev;

/** The `tool_response` of a hook payload: what a Bash call printed. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef HookToolResponse = {
	@:optional var stdout: String;
	@:optional var stderr: String;
};
