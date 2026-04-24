package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated parser of `BlockComment`.
 *
 * Replaces the pre-split `BlockCommentBodyParser` — the parser root
 * now is the `BlockComment` enum (with `DoubleStars` / `Plain`
 * variants), not the wrapper-less body struct. Variant selection is
 * driven by source-literal match on `@:lead` / `@:trail`.
 *
 * Empty class on purpose — the body is filled by `Build.buildParser`.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.BlockComment))
@:nullSafety(Strict)
class BlockCommentParser {}
