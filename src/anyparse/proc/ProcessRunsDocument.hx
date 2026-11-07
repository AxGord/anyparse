package anyparse.proc;

/** The answer of the process driver: one `ProcessRun` per job, in the order of the jobs (a schema cannot root on an array). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ProcessRunsDocument = {
	var runs: Array<ProcessRun>;
}
