package dev;

import anyparse.grammar.json.JValue;

/** One invocation of a parity suite or a probe kit: its arguments, its files, and for a kit its compile check and expectation. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SuiteInvocation = {
	var name: String;
	@:optional var note: String;
	@:optional var knownDefect: String;
	@:optional var fixpoint: String;
	@:optional var outShape: String;
	@:optional var outMinLines: Int;
	var argv: Array<String>;
	@:optional var stdin: String;

	/** File name to content; the keys are data. */
	@:optional var files: JValue;
	@:optional var compile: CompileSpec;
	@:optional var expect: Expectation;
};
