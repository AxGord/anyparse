package dev;

/** What an invocation of a probe kit is expected to answer, and what one answered. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef Expectation = {

	@:optional var exit: Null<Int>;
	var out: String;
	var err: String;
	var files: String;
	@:optional var compiles: Array<Bool>;

	/** Per define set: both programs ran and printed the same. */
	@:optional var sameRun: Array<Bool>;
	@:optional var onePass: Bool;
	@:optional var commentsKept: Bool;

};
