package anyparse.query.format.json;

/**
 * JSON shape for one `apq search` pattern-metavar binding.
 *
 * The spec's `bindings: { X: {text, span} }` uses metavar names as
 * dynamic JSON object keys; Phase 2 emits an array-of-bindings form
 * instead so the typed schema stays static and macro-generated. Phase
 * 4's JSON schema finalization will decide whether to switch to the
 * dynamic-key form; the array form is forward-compatible (consumers
 * can read both via a single normalization pass).
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstSearchBinding = {
	var name:String;
	var text:String;
	var span:AstSearchSpan;
};
