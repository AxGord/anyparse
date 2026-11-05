package dev;

/** `EdgeReading` as a revision's cache holds it: the files, and the edges as `[key, target]` pairs. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef EdgeReadingJson = {
	var files: Array<String>;
	var edges: Array<Array<String>>;
};
