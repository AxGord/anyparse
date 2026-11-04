package anyparse.check.oracle;

/** The file `ReachBuildsCache` keeps: the builds of one list of configurations under the fingerprint of their input. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ReachBuildsRecord = {
	var format: String;
	var key: String;
	var stats: Array<Array<String>>;
	var configurations: Array<ReachConfigurationRecord>;
	var library: Array<ReachLibraryRecord>;
}
