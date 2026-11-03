package dev;

/** What the agents of one slice cost (`OTHER` for those naming none), and whether the slice landed. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef SliceCost = {
	var slice: String;
	var agents: Int;
	var turns: Int;
	var output: Int;
	var cost: Float;
	var landed: Bool;
}
