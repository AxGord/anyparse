package dev;

/** The calls of one tool kind made by the agents of one role; sizes in tokens. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef RoleToolRow = {
	var role: String;
	var key: String;
	var calls: Int;
	var outTok: Int;
	var over5k: Int;

	/** The calls with the largest answers, the largest first. */
	var biggest: Array<BigCallRow>;
}
