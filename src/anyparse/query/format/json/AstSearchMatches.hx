package anyparse.query.format.json;

/**
 * Top-level envelope for `apq search` JSON output.
 *
 * The spec sketches a bare top-level array; Phase 2 wraps it in
 * `{matches: [...]}` so the macro-generated writer has a typedef root
 * to dispatch on. Consumers reading the spec form unwrap the envelope
 * — the change is forward-compatible.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstSearchMatches = {
	var matches: Array<AstSearchMatch>;
};
