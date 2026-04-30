package anyparse.format.text;

/**
 * Terminal for one line's leading whitespace inside a block-comment
 * body. Captures `[ \t]*` verbatim. The `BlockCommentNormalizer`
 * common-prefix-reduces across non-edge non-blank lines and re-emits
 * each line's residual relative to the surrounding writer's nest, so
 * a 4-space-indented source comment dropped into a tab-indented
 * target context lands aligned with the wrap.
 */
@:re('[ \\t]*')
@:rawString
abstract BlockCommentLineWs(String) from String to String {}
