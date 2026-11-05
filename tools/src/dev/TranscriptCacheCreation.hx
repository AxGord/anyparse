package dev;

/** The cache-write split of a transcript message's usage. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef TranscriptCacheCreation = {
	@:key('ephemeral_5m_input_tokens') @:optional var ephemeral5mInputTokens: Int;
	@:key('ephemeral_1h_input_tokens') @:optional var ephemeral1hInputTokens: Int;
};
