package unit.grammar.nativedoor;

import anyparse.grammar.json.JValue;

/** A record with raw parts and no map, so it has a writer: its compact options keep the Doc writer. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef DoorRawPart = {
	var id: String;
	var raw: JValue;
	var tuples: Array<Array<JValue>>;
}
