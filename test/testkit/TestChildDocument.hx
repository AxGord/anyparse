package testkit;

import anyparse.proc.SpawnJob;

/**
 * What a `TestChild` role reads from its input file or writes to its output file: the jobs it runs, the configurations it
 * prepares, the runs it answers.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef TestChildDocument = {
	@:optional var jobs: Array<SpawnJob>;
	@:optional var configs: Array<ChildOracleConfig>;
	@:optional var runs: Array<ChildRun>;
};
