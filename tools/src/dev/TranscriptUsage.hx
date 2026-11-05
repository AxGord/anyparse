package dev;

/** The token usage of a transcript message. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef TranscriptUsage = {
	@:key('input_tokens') @:optional var inputTokens: Int;
	@:key('output_tokens') @:optional var outputTokens: Int;
	@:key('cache_read_input_tokens') @:optional var cacheReadInputTokens: Int;
	@:key('cache_creation_input_tokens') @:optional var cacheCreationInputTokens: Int;
	@:key('cache_creation') @:optional var cacheCreation: TranscriptCacheCreation;
};
