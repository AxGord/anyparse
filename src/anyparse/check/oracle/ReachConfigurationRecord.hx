package anyparse.check.oracle;

/** One configuration's build, as `ReachBuildsCache` keeps it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ReachConfigurationRecord = {
	var name: String;
	var defined: Array<String>;
	var everDefined: Array<String>;
	var values: Array<Array<String>>;
	var compiled: Array<String>;
	var types: Array<ReachTypeRecord>;
	var ?parsed: Array<String>;
}
