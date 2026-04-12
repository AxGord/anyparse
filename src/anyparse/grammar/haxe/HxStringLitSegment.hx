package anyparse.grammar.haxe;

/**
 * Terminal for a run of literal characters (including escape sequences)
 * inside a single-quoted Haxe string.
 *
 * The regex matches one or more characters that are NOT `'` (which would
 * end the string), `\` (which starts an escape, handled by `\\.`), or
 * `$` (which starts interpolation). Escape sequences `\X` are included
 * in the same run so that `hello\nworld` is one `Literal` segment, not
 * three. The `@:decode` function processes `\X` sequences via
 * `HaxeFormat.instance.unescapeChar`.
 *
 * `@:raw` suppresses `skipWs` in the generated parse function — spaces
 * inside string content are significant, not whitespace to skip.
 *
 * `from String to String` keeps test assertion casts compiling.
 */
@:re("(?:[^'\\\\$]|\\\\.)+")
@:decode('anyparse.grammar.haxe.HxStringDecoder.decodeLiteral')
@:raw
abstract HxStringLitSegment(String) from String to String {}
