package anyparse.query.format.json;

/**
 * Top-level envelope for `apq refs` JSON output.
 *
 * Mirrors `AstSearchMatches`: the spec sketches a bare top-level
 * array, Phase 3.1 wraps it in `{hits: [...]}` so the macro-generated
 * writer has a typedef root to dispatch on. Consumers reading the
 * spec form unwrap the envelope — forward-compatible.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstRefHits = {
	var hits:Array<AstRefHit>;
};
