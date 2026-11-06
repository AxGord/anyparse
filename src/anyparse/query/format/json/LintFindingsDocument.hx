package anyparse.query.format.json;

/** An `apq lint --format json` report: a bare array of findings, written as the array alone (`@:bare`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws @:bare
typedef LintFindingsDocument = {

	var findings: Array<LintFindingRecord>;
};
