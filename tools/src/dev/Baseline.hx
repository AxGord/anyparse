package dev;

import anyparse.grammar.json.JValue;

/**
 * What `--baseline` records for the gate run, in `<logs>/baseline.json`.
 * The base suite is not among it: a gate reads it from `BaseSuite` when a row compares with it.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef Baseline = {

	var base: String;

	/** Each registry's line count, by its `--list-<name>` name; read and made through `BaselineLists`. */
	var lists: JValue;

	/** The base tree's whole lint by the base engine. */
	var lint: String;
	var infra: Array<InfraSnapshot>;
	var frozen: Array<FrozenTree>;

}
