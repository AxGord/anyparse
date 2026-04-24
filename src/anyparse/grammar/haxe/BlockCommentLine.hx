package anyparse.grammar.haxe;

/**
 * Terminal for one line of a captured multi-line `/*…*\/` body.
 *
 * Stores only the **content** of the line — leading whitespace and
 * any javadoc-style `*` marker are matched but dropped via
 * `@:captureGroup(1)`. Writer policy, not source, drives whether
 * output lines get wrap delimiters or leading `*` markers, so those
 * bytes are never round-tripped.
 *
 * Regex shape:
 *  - `[ \t]*` — leading whitespace (stripped).
 *  - `\**`   — optional run of `*` markers (javadoc style, stripped).
 *  - `[ \t]?` — at most one separator space after the markers
 *    (stripped so ` * foo` and `*foo` both yield `foo`).
 *  - `((?:(?!\*\/)[^\n])*)` — the content capture group. Negative
 *    lookahead `(?!\*\/)` keeps it from eating into the
 *    `BlockCommentBody.@:trail` close delimiter.
 *
 * `@:raw` suppresses `skipWs`: every character inside the body is
 * significant at parse time even though we throw away the leading
 * run at capture.
 */
@:re('[ \\t]*(?:\\*(?!/))*[ \\t]?((?:(?!\\*/)[^\\n])*)')
@:captureGroup(1)
@:rawString
abstract BlockCommentLine(String) from String to String {}
