package unit.grammar.nativedoor;

/** The nested record of the native-door fixtures. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef DoorInner = {
	var n: Int;
	@:optional var label: Null<String>;
}
