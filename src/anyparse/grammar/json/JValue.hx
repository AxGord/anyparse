package anyparse.grammar.json;

/**
 * Raw JSON AST — the universal schema for JSON, accepting any valid
 * document. Used when the caller does not have a specific typed schema.
 *
 * This enum is also the first grammar driven by the macro pipeline:
 * `@:build(anyparse.macro.Build.build())` triggers the five-pass
 * pipeline that reads the grammar metadata below and emits a sibling
 * class `JValueFastParser` with a static `parse(source):JValue` method
 * behaviorally equivalent to the hand-written `JsonParser`.
 *
 * The hand-written `JsonParser` remains in the repo as a regression
 * baseline; parity tests assert that the generated parser produces
 * identical results on the full existing test corpus.
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
