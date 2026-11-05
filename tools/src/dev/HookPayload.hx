package dev;

/** The event a hook reads on its standard input, as far as the developer tools read or send it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef HookPayload = {
	@:key('session_id') @:optional var sessionId: String;
	@:optional var cwd: String;
	@:key('tool_name') @:optional var toolName: String;
	@:key('tool_input') @:optional var toolInput: HookToolInput;
	@:key('tool_response') @:optional var toolResponse: HookToolResponse;
};
