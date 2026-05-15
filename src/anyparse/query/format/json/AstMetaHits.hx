package anyparse.query.format.json;

/**
 * Top-level envelope for `apq meta` JSON output.
 *
 * Mirrors `AstRefHits` / `AstSearchMatches`: the spec sketches a
 * bare top-level array, the implementation wraps it in
 * `{hits: [...]}` so the macro-generated writer has a typedef root
 * to dispatch on. Consumers reading the spec form unwrap the
 * envelope — forward-compatible.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstMetaHits = {
	var hits:Array<AstMetaHit>;
};
