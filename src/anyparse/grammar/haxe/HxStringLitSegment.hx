package anyparse.grammar.haxe;

/**
 * Terminal for a run of literal characters (including escape sequences)
 * inside a single-quoted Haxe string.
 *
 * The regex matches one or more characters that are NOT `'` (which would
 * end the string), `\` (which starts an escape, handled by `\\.`), or
 * `$` (which starts interpolation). Escape sequences `\X` are included
 * in the same run so that `hello\nworld` is one `Literal` segment, not
 * three. `@:unescape("singleQuoteRaw")` generates an inline walk-and-
 * unescape loop that processes `\X` sequences via
 * `HaxeFormat.unescapeChar` without stripping surrounding quotes (the
 * regex already matches the body only). On the writer side, the
 * `singleQuoteRaw` mode routes through `HaxeFormat.escapeSingleQuoteChar`
 * — the single-quote-aware escape table (escapes `'`, `$`, `\\` but
 * leaves bare `"` alone) so that strings like `'cat="active"'` round-
 * trip byte-perfect instead of being over-escaped to `'cat=\\"active\\"'`.
 *
 * `@:raw` suppresses `skipWs` in the generated parse function — spaces
 * inside string content are significant, not whitespace to skip.
 *
 * `from String to String` keeps test assertion casts compiling.
 */
@:re("(?:[^'\\\\$]|\\\\.)+")
@:unescape("singleQuoteRaw")
@:raw
abstract HxStringLitSegment(String) from String to String {}
