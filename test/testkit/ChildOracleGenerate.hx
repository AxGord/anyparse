package testkit;

/** An `OracleGenerate` as a `TestChild` role reads it from its input file. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ChildOracleGenerate = {
	var command: String;
	var root: String;
	@:optional var inputs: Null<Array<String>>;
	var probeDir: Bool;
};
