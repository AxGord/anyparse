package anyparse.query;

/**
 * What one project file contributes to `apq owner`, read off its parse alone: the entries of its types and members, and
 * the distinct words of its code, from which the scope's mention counts are folded (`OwnerIndex.fromOutlines`). A file
 * that did not parse holds neither. Stored per file (`ProjectOutlines`).
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef FileOwners = {
	var file: String;
	var parsed: Bool;
	var entries: Array<OutlineEntry>;
	var words: Array<String>;
}
