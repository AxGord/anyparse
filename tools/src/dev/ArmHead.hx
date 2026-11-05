package dev;

/** The keys of one arm record that name an arm and what it cuts; every other key is ignored. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ArmHead = {
	var name: String;
	@:optional var type: String;
	@:optional var method: String;
};
