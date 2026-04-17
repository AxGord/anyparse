package anyparse.grammar.json;

/**
 * Raw JSON AST — the universal schema for JSON, accepting any valid
 * document. Used when the caller does not have a specific typed schema.
 *
 * This enum is the grammar driving the JSON parser and writer:
 *  - `JValueParser` (marker class, macro-generated via
 *    `anyparse.macro.Build.buildParser`) — `parse(source):JValue`.
 *  - `JValueWriter` (marker class, macro-generated via
 *    `anyparse.macro.Build.buildWriter`) — `write(value):String`.
 *
 * Round-trip equivalence (`parse(write(ast)) == ast`) is the regression
 * invariant — enforced by `JsonRoundTripTest`.
 *
 * Metadata layer:
 *  - `@:peg` marks this as a grammar entry point.
 *  - `@:schema(JsonFormat)` binds the grammar to the literal vocabulary
 *    of `anyparse.format.text.JsonFormat`.
 *  - `@:ws` turns on cross-cutting whitespace consumption before every
 *    terminal in this grammar.
 *  - Per-constructor `@:lit` / `@:lead` / `@:trail` / `@:sep` metadata
 *    describe the literal glue for each JSON value shape.
 */
@:peg
@:schema(anyparse.format.text.JsonFormat)
@:ws
enum JValue {

	@:lit('null')
	JNull;

	@:lit('true', 'false')
	JBool(v:Bool);

	JNumber(v:JNumberLit);
	JString(v:JStringLit);

	@:lead('[') @:trail(']') @:sep(',')
	JArray(items:Array<JValue>);

	@:lead('{') @:trail('}') @:sep(',')
	JObject(entries:Array<JEntry>);
}
