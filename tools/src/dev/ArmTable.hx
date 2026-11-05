package dev;

/** The arm registry as one document holds it: the records under `arms`. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ArmTable = {
	@:optional var arms: Array<ArmRecordJson>;
};
