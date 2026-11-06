package dev;

/** The ways agents went round hxq: calls that ran, the heuristic script writes, and the attempts the gate hook denied. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef BypassSummary = {

	var shellHxReads: Int;

	/** Writes by `sed -i`, a redirect, `tee`, `cp`, `install`, `mv`, `Edit` or `Write`. */
	var hxWrites: Int;

	/** Interpreter scripts naming a `.hx` and calling a write: a heuristic, not a verdict. */
	var scriptWrites: Int;

	/** The reads and the writes the gate hook refused: attempts that never ran. */
	var deniedReads: Int;
	var deniedWrites: Int;
	var writePayloadTok: Int;

	/** The leading blanks among the write payload, in tokens. */
	var indentTok: Int;
	var readSamples: Array<String>;
	var writeSamples: Array<String>;
	var scriptSamples: Array<String>;

}
