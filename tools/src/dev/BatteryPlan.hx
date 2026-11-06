package dev;

/** What every process of one battery run reads: the run's options and what the driver decided before the branches forked. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef BatteryPlan = {

	var repo: String;
	var work: String;
	var cache: String;

	/** The commit this run's snapshot is keyed by. */
	var head: String;

	/** The snapshot compared against, or null on a first run. */
	@:optional var base: Null<String>;

	/** The base snapshot's suite counts (tests, assertions), or null. */
	@:optional var baseSuite: Null<Array<Int>>;

	/** The test classes the suite row runs instead of every class (`--only`), or null for the whole suite. */
	@:optional var only: Null<Array<String>>;
	var shards: Int;
	var quick: Bool;
	var snapshot: Bool;
	var allowBlast: Bool;

	/** The rows whose failure the verdict waives (`--allow`), each saying so. */
	var allow: Array<String>;

	/** The second, private tree linted (and blasted) beside this one, or null. */
	@:optional var client: Null<String>;

	/** Why the jvm probe does not apply, or null when it runs. */
	@:optional var jvmSkip: Null<String>;

	/**
	 * The files of the lint roots this landing re-lints, the base snapshot standing for the rest (`LintScope`), or null for the whole tree.
	 */
	@:optional var lintScope: Null<Array<String>>;

	/** The id the branches' reports carry (`Branches.newRunId`). */
	var run: String;

	/** Whether each branch takes its own lease of the pool: the suite then runs as many shards as its lease granted. */
	var ownLease: Bool;

	/** The gate record the run was offered (`--reuse`), or null. */
	@:optional var gate: Null<GateRecord>;

	/** The battery rows that record stands for (`GateReuse.rows`), each run as a reading of the gate instead of measured. */
	@:optional var reused: Null<Array<String>>;

};
