package unit.grammar.nativedoor;

/** A record the shape check reads whole and the compact writer writes: every field kind but a raw part and a map. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef DoorRecord = {
	@:optional var first: Null<String>;
	var name: String;
	var size: Int;
	var ratio: Float;
	var on: Bool;
	@:key('function') var member: String;
	var points: Array<Int>;
	var rows: Array<Array<String>>;
	var holes: Array<Null<String>>;
	var inner: DoorInner;
	var kids: Array<DoorInner>;
	@:optional var tail: Null<DoorInner>;
}
