package testkit;

/** An `OracleConfig` as a `TestChild` role reads it from its input file: every key but the run's own memo. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ChildOracleConfig = {
	var hxml: String;
	@:optional var dir: Null<String>;
	var defines: Array<String>;
	@:optional var generate: ChildOracleGenerate;
	@:optional var unavailable: String;
	@:optional var raced: String;
	@:optional var modules: Array<String>;
};
