package anyparse.format.comment;

/**
 * Marker class for the macro-generated parser of `BlockComment`.
 *
 * Engine-level: any C-family grammar reuses this single parser by
 * calling `BlockCommentNormalizer.processCapturedBlockComment`
 * (wired in the format's `defaultWriteOptions.blockCommentAdapter`).
 * Plugin grammars don't subclass or rebuild — one widget, all
 * languages.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.format.comment.BlockComment))
@:nullSafety(Strict)
class BlockCommentParser {}
