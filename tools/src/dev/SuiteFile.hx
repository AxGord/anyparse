package dev;

import anyparse.grammar.json.JValue;

/**
 * A parity suite or a probe kit as its JSON file holds it, read through this schema.
 * `Probe.write` records a kit on the raw document, so a key not declared here survives.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SuiteFile = {

	@:optional var about: String;
	@:optional var commandHelp: Bool;

	/** File name to content, shared by the invocations that name none; the keys are data. */
	@:optional var files: JValue;
	@:optional var compile: CompileSpec;
	@:optional var invocations: Array<SuiteInvocation>;

};
