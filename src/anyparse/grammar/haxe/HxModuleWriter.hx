package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated writer of `HxModule`.
 *
 * The `buildWriter` macro walks the same ShapeTree as `buildParser` but
 * emits Doc-building functions instead of parse functions, producing a
 * self-contained writer class that converts `HxModule` AST back to
 * formatted Haxe source text via the Doc IR and Renderer.
 */
@:build(anyparse.macro.Build.buildWriter(
	anyparse.grammar.haxe.HxModule,
	anyparse.grammar.haxe.HxModuleWriteOptions
))
@:nullSafety(Strict)
class HxModuleWriter {}
