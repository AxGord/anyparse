package anyparse.query.format.json;

/**
 * The `data` of a written lint finding (`Check.FindingData`): its identity, the evidence chain, and the repeating calls
 * that run it more than once when the rule names them. `function` is a Haxe keyword, so the field is `member`.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintFindingDataRecord = {

	var family: String;

	@:key('function') var member: String;

	var subject: String;

	var chain: Array<String>;

	@:optional var repeatedBy: Null<Array<LintRepeatSiteRecord>>;
};
