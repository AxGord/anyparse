package dev;

/** One node of a V8 CPU profile: its id, its frame and the ids of its children. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ProfileNode = {
	var id: Int;
	var callFrame: ProfileFrame;
	@:optional var children: Array<Int>;
};
