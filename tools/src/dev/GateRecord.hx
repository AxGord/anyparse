package dev;

/**
 * What a slice gate's check leaves in `<logs>/gate-record.json`: the tree it judged, its verdict, and the readings a land
 * of that very tree may take over instead of measuring again (`GateReuse`).
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef GateRecord = {
	/** The gated tip's tree id (`git rev-parse HEAD^{tree}`), the one thing a land compares its merge with. */
	var tree: String;

	var passed: Bool;

	/** The compiler that built the binaries the rows ran (`BaseEngine.toolchain`). */
	var toolchain: String;

	/** The corpus fork's state (`GateReuse.forkState`), empty when none was set. */
	var fork: String;

	/** The rows the gate's `--allow` waived, by their gate names. */
	var allow: Array<String>;

	/** The gate rows that passed, by their gate names. */
	var rows: Array<String>;

	var tests: Int;
	var assertions: Int;

	/** The corpus snapshot the gate's suite left, copied into the gate's logs, or null when the suite ran no corpus. */
	@:optional var sweep: Null<String>;
}
