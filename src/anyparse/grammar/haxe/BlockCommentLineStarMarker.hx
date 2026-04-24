package anyparse.grammar.haxe;

/**
 * Terminal for the javadoc-style `*` marker that introduces a
 * body line in a block comment. Captures the star itself plus an
 * optional single separator space after — no leading whitespace
 * (that lives in the preceding `BlockCommentLineWs` field).
 *
 * Regex shape:
 *  - `\*` — the `*` marker proper.
 *  - `(?!\*?\/)` — negative lookahead. Protects against eating the
 *    `*` that opens the body close delimiter.
 *  - `[ \t]?` — at most one separator space after the marker,
 *    absorbed so source ` * foo` and `*foo` both yield `foo` as
 *    the content terminal's match.
 *
 * Used as the middle field of `BlockCommentStarredLine`
 * (ws + marker + content). Source ` * foo` parses as
 * ws=` `, marker=`* `, content=`foo`.
 */
@:re('\\*(?!\\*?/)[ \\t]?')
@:rawString
abstract BlockCommentLineStarMarker(String) from String to String {}
