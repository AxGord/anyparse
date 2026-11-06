package anyparse.query.format.json;

/**
 * One written scoring bucket (`LintScore.LintScoreBucket`): its counts, the matched keys per verdict, and the precision
 * and recall — `null` over a zero denominator.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintScoreBucketRecord = {

	var family: String;

	var findings: Int;

	var keys: Int;

	var duplicates: Int;

	var matched: LintScoreVerdictCounts;

	var unlabelled: Int;

	@:optional @:writeNull var precision: Null<Float>;

	var recallEntries: Int;

	var recallHit: Int;

	@:optional @:writeNull var recall: Null<Float>;
};
