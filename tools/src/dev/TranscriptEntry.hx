package dev;

/** One line of a Claude Code transcript, as far as `TokenTranscript` reads it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef TranscriptEntry = {
	@:optional var type: String;
	@:optional var timestamp: String;

	/** The directory the agent's shell was in. */
	@:optional var cwd: String;
	@:optional var message: TranscriptMessage;
};
