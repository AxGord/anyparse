package dev;

/** The cache writes split into the first fill, ordinary appends and rewrites, with the gaps before the rewrites. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef RewriteSummary = {
	var turns: Int;
	var rewrites: Int;
	var rewriteTokens: Int;
	var appendTokens: Int;
	var initialTokens: Int;
	var extraCost: Float;
	var gapMedianSeconds: Float;
	var gapMaxSeconds: Float;

	/** The rewrites whose gap was within the 5-minute cache lifetime, within the 1-hour one, and beyond it. */
	var within5m: Int;

	var to1h: Int;
	var over1h: Int;
	var worst: Array<Rewrite>;
}
