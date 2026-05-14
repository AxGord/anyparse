package anyparse.query.format.json;

/**
 * JSON shape for a single `apq refs` hit.
 *
 * Matches the spec sketch in `docs/cli-query-tool.md`:
 *
 *   { file:String, kind:"read"|"write"|"decl", span:Span, name:String }
 *
 * `kind` is rendered as the plain string per the spec.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstRefHit = {
	var file:String;
	var kind:String;
	var span:AstSearchSpan;
	var name:String;
};
