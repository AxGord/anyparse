package anyparse.query.format.json;

/**
 * JSON shape for a single `apq refs` hit.
 *
 * Matches the spec sketch in `docs/cli-query-tool.md`:
 *
 *   { file:String, kind:"read"|"write"|"decl", span:Span, name:String,
 *     ?binding:Span }
 *
 * `kind` is rendered as the plain string per the spec.
 *
 * `binding` is the span of the declaration this hit resolves to.
 * Decl hits self-bind (`binding == span`). Read hits point to the
 * innermost enclosing decl with a matching name; the field is
 * omitted when the read is unresolved (cross-file / implicit-`this`).
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstRefHit = {
	var file:String;
	var kind:String;
	var span:AstSearchSpan;
	var name:String;
	@:optional var binding:AstSearchSpan;
};
