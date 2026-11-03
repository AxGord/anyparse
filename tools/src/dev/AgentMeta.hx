package dev;

/** The `.meta.json` beside a Claude Code transcript: the one-line task of its agent. Read by `AgentMetaParser`. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef AgentMeta = {

	@:optional var description: String;
};
