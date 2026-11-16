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

	/**
	 * The node version the suite and the kits ran under (`GateReuse.nodeVersion`); a record without it is an older one, which no
	 * land takes rows from.
	 */
	@:optional
	var node: Null<String>;

	/** The corpus fork's state (`GateReuse.forkState`), empty when none was set. */
	var fork: String;

	/** The rows the gate's `--allow` waived, by their gate names. */
	var allow: Array<String>;

	/** The gate rows that passed, by their gate names. */
	var rows: Array<String>;
	var tests: Int;
	var assertions: Int;

	/**
	 * How many test classes an impact-selected suite selected, whether it ran them or kept them from an earlier check's
	 * pass (`SuiteReuse`), or null when the suite ran every class.
	 */
	@:optional
	var impact: Null<Int>;

	/** The corpus snapshot the gate's suite left, copied into the gate's logs, or null when the suite ran no corpus. */
	@:optional
	var sweep: Null<String>;

	/**
	 * The gate's rows as `ExecLedger` lines (`ExecLedger.encode`), so a land taking its rows over carries what they cost;
	 * null on a record an older gate wrote.
	 */
	@:optional
	var timings: Null<Array<String>>;

	/**
	 * The test classes whose pass the record's tree holds when its suite ran only the classes its change reaches: those it ran
	 * and those it kept from an earlier record (`SuiteReuse`); null when the suite ran every class.
	 */
	@:optional
	var vouched: Null<Array<String>>;

}
