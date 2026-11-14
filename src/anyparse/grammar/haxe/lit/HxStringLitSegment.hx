package anyparse.grammar.haxe.lit;

/**
 * Terminal for a run of literal characters (including escape sequences)
 * inside a single-quoted Haxe string.
 *
 * The regex matches one or more characters that are NOT `'` (which would
 * end the string), `\` (which starts an escape, handled by `\\.`), or
 * `$` (which starts interpolation). Escape sequences are included in
 * the same run so that `hello\nworld` is one `Literal` segment, not
 * three. Only the escapes haxe takes match (`\n \r \t \" \' \\`, a
 * `\NNN` octal up to `\177`, `\x00`..`\x7F`, `\uNNNN`, `\u{…}` of
 * up to six significant digits after any leading zeros); any other `\X` ends the run and fails the parse, as it
 * does in haxe. `@:rawString` instructs the parser to store the matched slice
 * VERBATIM — escape sequences NOT decoded — and the writer to emit it
 * unchanged. This preserves source form byte-perfect through round-trip:
 * a literal embedded newline (multiline `'...'`) stays a real newline,
 * and an escape sequence (`\n`, `\'`, `\\`) stays as its two-character
 * escape. Mirrors `HxDoubleStringLit` and haxe-formatter's
 * source-verbatim approach.
 *
 * Why not `@:unescape`: decode+re-encode is lossy at the source-form
 * boundary — a real newline and `\n` decode to the same value, so a
 * re-escaping writer would collapse both and corrupt multiline strings.
 *
 * `@:raw` suppresses `skipWs` in the generated parse function — spaces
 * inside string content are significant, not whitespace to skip.
 *
 * `from String to String` keeps test assertion casts compiling. The
 * underlying `String` is the raw source slice (escapes intact), NOT a
 * decoded value; a consumer needing the decoded runtime value calls
 * `HxStringEscape`.
 *
 * The regex stops at a RAW `$`, which is NOT every `$` the compiler
 * sees: it decodes escapes BEFORE it scans for interpolation, so a
 * `\x24` inside this run is a live trigger (`'\x24a'` is the value of
 * the local `a`). A `Literal` segment therefore UNDER-reports
 * interpolation by construction — `HxInterpProjection` re-splits it in
 * the query tree, which is where consumers ask. The parse tree keeps
 * the author's spelling, as the writer needs.
 */
@:re("(?:[^'\\\\$]|\\\\(?:[nrt\"'\\\\]|[01][0-7][0-7]|x[0-7][0-9a-fA-F]|u(?:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]|\\{(?:0+(?:[1-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F])?)?)?)?)?)?|[1-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F](?:[0-9a-fA-F])?)?)?)?)?)\\})))+")
@:rawString
@:raw
abstract HxStringLitSegment(String) from String to String {}
