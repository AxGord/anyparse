package anyparse.query.format.json;

/**
 * A key of a written `apq lint-score` result: `family`, `function` (the `member`) and `subject`; a lost recall entry adds
 * its `verdict`, an unlabelled key its finding `count` and `file`.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintScoreKeyRecord = {
	var family: String;
	@:key('function') var member: String;
	var subject: String;
	@:optional var verdict: Null<String>;
	@:optional var count: Null<Int>;
	@:optional var file: Null<String>;
};
