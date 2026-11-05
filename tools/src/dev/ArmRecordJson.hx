package dev;

import anyparse.grammar.json.JValue;

/** One record of the arm registry as its JSON holds it: `find` and `replace` are one string or a list, `force` a scalar. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ArmRecordJson = {
	var name: String;
	var type: String;
	var method: String;
	@:optional var kind: String;
	@:optional var force: JValue;
	@:optional var find: JValue;
	@:optional var replace: JValue;
};
