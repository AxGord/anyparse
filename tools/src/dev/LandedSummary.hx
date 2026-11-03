package dev;

/** What the landed slices cost together and each. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef LandedSummary = {
	var slices: Int;
	var cost: Float;
	var perSlice: Float;
}
