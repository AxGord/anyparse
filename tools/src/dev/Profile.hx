package dev;

/** A V8 `.cpuprofile` as far as `prof-top` reads it: the call tree and the node sampled at each tick, with the time since the last. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef Profile = {
	var nodes: Array<ProfileNode>;
	var samples: Array<Int>;
	var timeDeltas: Array<Float>;
};
