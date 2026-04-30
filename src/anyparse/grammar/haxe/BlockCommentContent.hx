package anyparse.grammar.haxe;

/**
 * Body content of a `BlockComment`, captured verbatim between `/*`
 * and `*\/`.
 *
 * Regex `(?:(?!\*\/)[\s\S])*` matches any character (including
 * newlines) while the next two bytes are not the close delimiter,
 * stopping greedily at the first `*\/`. The captured slice is the
 * full comment body as the author wrote it — `*` runs adjacent to
 * the wrap delimiters fall into content as ordinary bytes, no
 * special handling.
 *
 * `@:rawString` stores the matched slice verbatim (no decoder pass).
 */
@:re('(?:(?!\\*/)[\\s\\S])*')
@:rawString
abstract BlockCommentContent(String) from String to String {}
