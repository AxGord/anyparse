package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated Fast-mode parser of
 * `BlockCommentBody` — splits a captured multi-line `/*…*\/` comment
 * body into a typed `BlockCommentLine` list at write time.
 *
 * Empty class on purpose — the body is filled by `Build.buildParser`.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.BlockCommentBody))
@:nullSafety(Strict)
class BlockCommentBodyParser {}
