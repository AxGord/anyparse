package dev;

/** The `tool_input` of a hook payload: the shell command of a Bash call. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef HookToolInput = {
	@:optional var command: String;
};
