package unit.grammar.nativedoor;

import anyparse.grammar.json.JValue;

/** A record with raw parts and a map: the shape check converts them, and only the Doc side could write them. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef DoorRawRecord = {
	var id: String;
	var raw: JValue;
	@:optional var maybe: Null<JValue>;
	var tuples: Array<Array<JValue>>;
	@:optional var named: Null<Map<String, DoorInner>>;
}
