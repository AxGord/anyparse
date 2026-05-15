package anyparse.query.format.json;

/**
 * JSON shape for a single `apq meta` hit.
 *
 * Matches the spec sketch in `docs/cli-query-tool.md`:
 *
 *   { file:String, annotation:String, args:Array<String>,
 *     decl:{ kind, ?name, span } }
 *
 * `annotation` is the verbatim source tag (e.g. `@:foo`). `args` is
 * the per-argument source text (`[]` when the annotation takes
 * none). `decl` carries the declaration the annotation is attached
 * to — see `AstMetaDecl`.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstMetaHit = {
	var file:String;
	var annotation:String;
	var args:Array<String>;
	var decl:AstMetaDecl;
};
