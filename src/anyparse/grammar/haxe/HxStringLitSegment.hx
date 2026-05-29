package anyparse.grammar.haxe;

/**
 * Terminal for a run of literal characters (including escape sequences)
 * inside a single-quoted Haxe string.
 *
 * The regex matches one or more characters that are NOT `'` (which would
 * end the string), `\` (which starts an escape, handled by `\\.`), or
 * `$` (which starts interpolation). Escape sequences `\X` are included
 * in the same run so that `hello\nworld` is one `Literal` segment, not
 * three. `@:rawString` instructs the parser to store the matched slice
 * VERBATIM — escape sequences NOT decoded — and the writer to emit it
 * unchanged. This preserves source form byte-perfect through round-trip:
 * a literal embedded newline (multiline `'...'`) stays a real newline,
 * and an escape sequence (`\n`, `\'`, `\\`) stays as its two-character
 * escape. Mirrors `HxDoubleStringLit` and haxe-formatter's
 * source-verbatim approach.
 *
 * Why not `@:unescape`: decode+re-encode is lossy at the source-form
 * boundary. A real newline and the escape `\n` decode to the same
 * runtime value, so a re-escaping writer cannot tell which form the
 * source carried — it collapses both to `\n` and corrupts genuine
 * multiline strings. `@:rawString` skips the decode pass entirely, so
 * whichever form the source used is preserved.
 *
 * `@:raw` suppresses `skipWs` in the generated parse function — spaces
 * inside string content are significant, not whitespace to skip.
 *
 * `from String to String` keeps test assertion casts compiling. The
 * underlying `String` is the raw source slice (escapes intact), NOT a
 * decoded value; a consumer needing the decoded runtime value must call
 * a decoder helper.
 */
@:re("(?:[^'\\\\$]|\\\\.)+")
@:rawString
@:raw
abstract HxStringLitSegment(String) from String to String {}
