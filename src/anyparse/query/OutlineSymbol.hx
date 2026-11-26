package anyparse.query;

/** One top-level declaration of a `FileSymbols`: what an `apq symbols` row says of it, less the file the record names. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef OutlineSymbol = {
	var qualified: String;
	var name: String;
	var kind: String;
	var line: Int;
	var col: Int;
}
