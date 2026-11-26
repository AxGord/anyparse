package anyparse.query;

/**
 * One declaration of a `FileOwners` as `OwnerIndex` ranks it, less what is not the file's own: the file the record names,
 * and the mention count, which the whole scope's code words decide.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef OutlineEntry = {
	var type: String;
	var ?member: Null<String>;
	var line: Int;
	var summary: String;
	var ?question: Null<String>;
	var nameTerms: Array<String>;
	var questionTerms: Array<String>;
	var summaryTerms: Array<String>;
	var docTerms: Array<String>;
}
