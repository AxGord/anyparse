package anyparse.query.format.json;

/**
 * One finding of an `apq lint --format json` report as it is written, key order and all (`LintFormat.json`): where it
 * is — a null position for a finding with no span — its severity, rule and message, the rule's structured identity
 * when it attaches one, and the selector of its node when the run resolves one. `LintFindingJson` is what a reader of
 * the report models of it.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintFindingRecord = {

	var file: String;

	@:optional @:writeNull var line: Null<Int>;

	@:optional @:writeNull var col: Null<Int>;

	@:optional @:writeNull var endLine: Null<Int>;

	@:optional @:writeNull var endCol: Null<Int>;

	var severity: String;

	var rule: String;

	var message: String;

	@:optional var data: Null<LintFindingDataRecord>;

	@:optional var address: Null<String>;
};
