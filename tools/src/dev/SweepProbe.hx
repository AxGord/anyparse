package dev;

/** One probe of a trap catalog: the file it probes and its text. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SweepProbe = {
	var file: String;
	@:optional var text: Array<String>;
};
