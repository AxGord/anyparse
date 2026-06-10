package anyparse.query.format.json;

/**
 * JSON shape for a single `apq search` match.
 *
 * Matches the spec sketch in `docs/cli-query-tool.md` (modulo the
 * bindings-as-array deviation documented in `AstSearchBinding`):
 *
 *   { file:String, span:Span, bindings:Array<{name,text,span}> }
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstSearchMatch = {
	var file: String;
	var span: AstSearchSpan;
	var bindings: Array<AstSearchBinding>;
};
