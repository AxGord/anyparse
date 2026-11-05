package dev;

/** A `--format json` lint report in the envelope a schema roots on: the bare array it prints, under `findings`. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ReportRecords = {
	var findings: Array<ReportRecord>;
};
