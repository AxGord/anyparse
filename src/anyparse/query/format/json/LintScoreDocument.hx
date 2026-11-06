package anyparse.query.format.json;

/**
 * The `apq lint-score --format json` document: what was scored, the overall and per-family buckets, the lost recall
 * and the unlabelled keys.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintScoreDocument = {
	var rule: String;
	var project: String;
	var commit: String;
	var severity: String;
	var excluded: Int;
	var overall: LintScoreBucketRecord;
	var families: Array<LintScoreBucketRecord>;
	var lost: Array<LintScoreKeyRecord>;
	var unlabelled: Array<LintScoreKeyRecord>;
};
