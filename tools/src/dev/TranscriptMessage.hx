package dev;

import anyparse.grammar.json.JValue;

/** The message of a transcript line. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef TranscriptMessage = {
	@:optional var id: String;
	@:optional var model: String;

	/** A string (the prompt) or a list of blocks. */
	@:optional var content: JValue;
	@:optional var usage: TranscriptUsage;
};
