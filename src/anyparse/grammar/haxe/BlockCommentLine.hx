package anyparse.grammar.haxe;

/**
 * Terminal for one line of a captured multi-line `/*…*\/` body.
 *
 * Matches any sequence of characters that is not `\n` and does not
 * start a `*\/` close delimiter, via PCRE negative lookahead
 * `(?!\*\/)`. `*`-quantifier lets empty lines between consecutive
 * `\n`s parse as zero-length matches — semantically meaningful blank
 * lines inside doc blocks.
 *
 * The negative-lookahead guard is load-bearing: without it the regex
 * would eat the final `*\/` as line content and leave nothing for
 * `BlockCommentBody.@:trail` to match. (The outer Star's entry peek
 * is `peekLit` over the full `*\/`, so an element whose first byte
 * equals `*` no longer short-circuits the loop.)
 *
 * `@:raw` suppresses `skipWs` in the generated parse function: every
 * character inside the comment body is significant, including
 * leading whitespace carrying source indentation for re-indent.
 *
 * `@:rawString` uses the matched slice directly as the result value
 * instead of running it through the JSON string-unescape helper.
 */
@:re('(?:(?!\\*/)[^\\n])*')
@:rawString
abstract BlockCommentLine(String) from String to String {}
