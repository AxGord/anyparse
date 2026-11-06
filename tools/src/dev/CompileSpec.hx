package dev;

/** How a probe invocation is compiled: the compiler arguments, the directory, the define sets and whether the program runs. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef CompileSpec = {

	var args: Array<String>;
	@:optional var dir: String;
	@:optional var defines: Array<Array<String>>;

	/** Whether the compile runs the program (`--interp`), and the files the invocation started from run too, to compare what both print. */
	@:optional var run: Bool;

};
