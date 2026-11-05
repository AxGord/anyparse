package dev;

/** One record of a `--format json` lint report, as far as a census reads it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ReportRecord = {
	var file: String;
	var line: Int;
	var col: Int;
	var message: String;
};
