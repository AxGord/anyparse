package anyparse.check.oracle;

/** A type one configuration compiled, as `ReachBuildsCache` keeps it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ReachTypeRecord = {
	var name: String;
	var file: String;
}
