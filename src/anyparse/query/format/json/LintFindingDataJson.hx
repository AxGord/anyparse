package anyparse.query.format.json;

/**
 * Declarative schema for the `data` object of an `apq lint --format json` record — the structured identity a rule
 * attaches to its findings (`Check.FindingData`). `function` is a Haxe keyword, so the field is `member` and its key is
 * declared with `@:key`. `chain` is evidence, never a key: a re-rendered chain is not a moved finding.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintFindingDataJson = {

	var family: String;

	@:key('function') var member: String;

	var subject: String;

	@:optional var chain: Null<Array<String>>;
};
