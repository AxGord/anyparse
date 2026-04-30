package anyparse.format.text;

/**
 * Marker class for the macro-generated writer of `BlockComment`.
 *
 * `@:fmt(preWrite(BlockCommentNormalizer.normalize))` on the
 * `BlockComment` typedef wraps `writeDoc` so the AST→AST normalize
 * fires once at entry — common-prefix-reduce + bake indent unit on
 * each line's `ws` field. The `@:sep('\n')` hardline-join then
 * routes each adjusted line through the surrounding writer's nest.
 */
@:build(anyparse.macro.Build.buildWriter(
	anyparse.format.text.BlockComment,
	anyparse.format.WriteOptions
))
@:nullSafety(Strict)
class BlockCommentWriter {}
