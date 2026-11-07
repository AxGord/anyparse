package testkit;

/** One `ProcessRun` as a `TestChild` role writes it to its output file and the parent reads it back. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ChildRun = {
	@:optional var status: Null<Int>;
	var out: String;
	var err: String;
	var failure: String;
	var overflowed: Bool;
	@:optional var cancelled: Bool;
	@:optional var unstarted: Bool;
};
