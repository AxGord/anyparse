package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated writer of `BlockComment`.
 *
 * `buildWriter` walks the same ShapeTree as `buildParser` and emits
 * round-trip write functions — emitting the `@:lead` / `@:trail`
 * literals from each variant's meta and concatenating `ws + content`
 * fields for each interior `BlockCommentLine`. Writer is agnostic to
 * `commentStyle` — the normalizer (`HaxeCommentNormalizer`) produces
 * a canonical AST with the target variant and canonical line `ws`,
 * and the writer faithfully emits that AST.
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
