package anyparse.grammar.haxe;

/**
 * Double-quoted Haxe string literal terminal.
 *
 * Matches a complete `"..."` string including the surrounding quotes.
 * `@:rawString` instructs the parser to store the matched slice
 * VERBATIM — outer quotes included, escape sequences NOT decoded —
 * and the writer to emit it unchanged. This preserves source form
 * byte-perfect through round-trip: literal embedded newlines stay
 * literal (multiline strings), escape sequences (`\n`, `\"`, `\\`)
 * stay as escapes. Mirrors haxe-formatter's source-verbatim approach.
 *
 * Why not `@:unescape`: decode+re-encode is lossy at the source-form
 * boundary. `"<newline><newline>"` and `"\n\n"` decode to the same
 * runtime value, so the writer cannot know which form to re-emit.
 * Fork preserves whichever form the source carried; we match by
 * skipping the decode pass entirely.
 *
 * Trade-off: the underlying `String` is the raw source slice (with
 * quotes and escapes), NOT a decoded value. Consumers wanting the
 * decoded runtime value call `HxStringEscape` — which is what any
 * rewrite MOVING this content into a single-quoted context has to do,
 * since Haxe decodes before it scans for interpolation and a `\x24`
 * that is plain text here becomes a live `$` there.
 *
 * `from String to String` keeps test assertion literals compiling
 * without explicit casts.
 */
@:re('"(?:[^"\\\\]|\\\\.)*"')
@:rawString
abstract HxDoubleStringLit(String) from String to String {}
