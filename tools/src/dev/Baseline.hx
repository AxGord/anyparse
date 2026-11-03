package dev;

import anyparse.grammar.json.JValue;

/** What `--baseline` records for the gate run, in `<logs>/baseline.json`. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef Baseline = {
	var base: String;
	var tests: Int;
	var assertions: Int;

	/** Each registry's line count, by its `--list-<name>` name; read and made through `BaselineLists`. */
	var lists: JValue;

	/** The corpus snapshot, or null when the suite ran no corpus. */
	@:optional var sweep: Null<String>;

	/** The base tree's whole lint by the base engine. */
	var lint: String;

	var infra: Array<InfraSnapshot>;
	var frozen: Array<FrozenTree>;
}
