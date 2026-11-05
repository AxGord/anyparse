package dev;

/** The `hookSpecificOutput` of a hook's answer. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef HookSpecificOutput = {
	@:optional var hookEventName: String;
	@:optional var permissionDecision: String;
	@:optional var additionalContext: String;
};
