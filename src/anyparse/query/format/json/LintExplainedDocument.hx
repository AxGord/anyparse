package anyparse.query.format.json;

/** An `apq lint --explain-long --format json` report: the findings, and why each lock is long — `null` with no report. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintExplainedDocument = {

	var findings: Array<LintFindingRecord>;

	@:optional @:writeNull var longLocks: Null<LongLocksRecord>;
};
