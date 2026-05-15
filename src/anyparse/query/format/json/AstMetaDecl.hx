package anyparse.query.format.json;

/**
 * JSON shape for the declaration an annotation is attached to in
 * `apq meta` output.
 *
 * Matches the spec sketch in `docs/cli-query-tool.md`:
 *
 *   { kind:String, ?name:String, span:Span }
 *
 * `name` is `@:optional` — most declarations carry a human-facing
 * identifier; the writer omits the key when the runtime value is
 * null (anonymous decls), matching the schema sketch.
 *
 * Lives in its own top-level module so the macro pipeline's
 * `optionsComplexType` path resolution does not hit the sub-module
 * gotcha (see `AstNodeJson` for the same rationale).
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstMetaDecl = {
	var kind:String;
	@:optional var name:String;
	var span:AstSearchSpan;
};
