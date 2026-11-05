package dev;

/** What a hook prints on its standard output, as far as the developer tools read or send it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef HookAnswer = {
	@:optional var hookSpecificOutput: HookSpecificOutput;
};
