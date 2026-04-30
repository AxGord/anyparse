package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated writer of `BlockComment`.
 *
 * `buildWriter` walks the same ShapeTree as `buildParser` and emits
 * `/*` + content + `*\/`. Content is written byte-identical to source
 * (verbatim round-trip). Optional canonicalization to a fixed style
 * (`Plain` / `Javadoc` / `JavadocNoStars`) lives in
 * `HaxeCommentNormalizer.processCapturedBlockComment`, which is the
 * adapter entry point — that path may transform the content string
 * before constructing the `BlockComment` AST handed to this writer.
 *
 * Exposes `write(value, ?opt):String` (via Renderer) and
 * `writeDoc(value, ?opt):Doc` (raw Doc for embedding in enclosing
 * writer streams — see `publicDocEntry` in `WriterCodegen`).
 */
@:build(anyparse.macro.Build.buildWriter(
	anyparse.grammar.haxe.BlockComment,
	anyparse.format.WriteOptions
))
@:nullSafety(Strict)
class BlockCommentWriter {}
