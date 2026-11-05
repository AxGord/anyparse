package devkit;

/** One step of a branch report, its outcome spelled as a label and a reason. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef StepRecord = {
	var name: String;
	var outcome: String;
	var why: String;
	var ms: Float;
	var note: String;

	/** The lines that decide the step; absent in a report an older tool left. */
	@:optional var excerpt: Array<String>;
};
