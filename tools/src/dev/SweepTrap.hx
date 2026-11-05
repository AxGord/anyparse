package dev;

import anyparse.grammar.json.JValue;

/** One trap of the catalog: its files, and the probes that run over them. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SweepTrap = {
	var name: String;

	/** File name to its lines, as a JSON object: the keys are data. */
	var files: JValue;
	var probes: Array<SweepProbe>;
};
