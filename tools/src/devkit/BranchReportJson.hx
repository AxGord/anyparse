package devkit;

/** A branch report as its file holds it: the run, the steps and the counts read. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef BranchReportJson = {
	/** The run whose branch left it; absent in a report that names none. */
	@:optional var run: String;

	var steps: Array<StepRecord>;
	var readings: Array<Reading>;
};
