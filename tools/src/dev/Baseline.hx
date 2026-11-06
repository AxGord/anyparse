package dev;

import anyparse.grammar.json.JValue;

/**
 * What `--baseline` records for the gate run, in `<logs>/baseline.json`.
 * The base suite and the base tree's lint are not among it: a gate reads them from `BaseSuite` and `BaseLint` when a row
 * compares with them.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef Baseline = {

	var base: String;

	/** Each registry's line count, by its `--list-<name>` name; read and made through `BaselineLists`. */
	var lists: JValue;

	/** Each infra tree's lint by the base engine; the base tree's own is `BaseLint`'s, read when a gate compares with it. */
	var infra: Array<InfraSnapshot>;
	var frozen: Array<FrozenTree>;

}
