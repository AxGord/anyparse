package anyparse.grammar.haxe;

/**
 * Terminal for one line's content inside a block-comment body,
 * after leading whitespace (`BlockCommentLineWs` for plain lines)
 * or after the javadoc star marker (`BlockCommentLineStarMarker`
 * for starred lines) has been consumed.
 *
 * Captures raw content verbatim — no star-marker stripping (that
 * lives in `BlockCommentLineStarMarker`'s regex now), no leading-
 * ws stripping (that's `BlockCommentLineWs`). The split across
 * three terminals keeps each one responsible for a single
 * syntactic element; writer round-trips by concatenating.
 *
 * Regex: `(?:(?!\*\*?\/)[^\n])*` — match any non-newline char not
 * at a body-close delimiter (`*\/` or `**\/`). Lookahead
 * `(?!\*\*?\/)` handles both close shapes.
 */
@:re('(?:(?!\\*\\*?/)[^\\n])*')
@:rawString
abstract BlockCommentLineContent(String) from String to String {}
