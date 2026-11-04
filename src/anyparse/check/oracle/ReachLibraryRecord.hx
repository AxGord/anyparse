package anyparse.check.oracle;

/** A library source a build read, with the hash of its text, as `ReachBuildsCache` keeps it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ReachLibraryRecord = {
	var file: String;
	var hash: String;
}
