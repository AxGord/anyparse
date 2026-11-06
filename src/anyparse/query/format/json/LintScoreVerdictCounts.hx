package anyparse.query.format.json;

/**
 * A written scoring bucket's matched keys per verdict: its keys are `LintScore.VERDICTS`, in that order, and a verdict
 * added there is added here. A verdict is no Haxe identifier (`real-long`) or is a keyword (`false`), so each field
 * declares its key.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintScoreVerdictCounts = {

	@:key('real-long') var realLong: Int;

	@:key('real-short') var realShort: Int;

	var rare: Int;

	@:key('false') var falseVerdict: Int;

	@:key('dup-of') var dupOf: Int;

	var unknown: Int;
};
