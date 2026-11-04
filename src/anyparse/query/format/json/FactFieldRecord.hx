package anyparse.query.format.json;

/** A field access a facts file's node record holds, with how its value is used (`FactUseRecord`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactFieldRecord = {
	var ?o: String;
	var f: String;
	var a: String;
	var r: String;
	var t: String;
	var ?w: Bool;
	var p: Array<Int>;
	var ?u: String;
	var ?m: String;
	var ?fresh: Bool;
	var ?h: Bool;
	var ?ag: String;
	var ?aa: String;
	var ?ai: Int;
}
