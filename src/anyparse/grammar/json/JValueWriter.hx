package anyparse.grammar.json;

/**
 * Marker class for the macro-generated writer of `JValue`.
 *
 * The `buildWriter` macro walks the same ShapeTree as `buildParser` but
 * emits Doc-building functions instead of parse functions, producing a
 * self-contained writer class that converts a `JValue` AST back to a
 * formatted JSON string via the Doc IR and Renderer.
 */
@:build(anyparse.macro.Build.buildWriter(
	anyparse.grammar.json.JValue,
	anyparse.grammar.json.JValueWriteOptions
))
@:nullSafety(Strict)
class JValueWriter {}
