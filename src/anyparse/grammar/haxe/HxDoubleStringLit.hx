package anyparse.grammar.haxe;

/**
 * Double-quoted Haxe string literal terminal.
 *
 * Matches a complete `"..."` string including the surrounding quotes.
 * `@:unescape` generates an inline walk-and-unescape loop that strips
 * the quotes and decodes `\X` sequences via `HaxeFormat.unescapeChar`.
 *
 * A separate type so the AST preserves which quote style the source
 * used — needed for round-trip writers.
 *
 * `from String to String` keeps test assertion literals compiling
 * without explicit casts.
 *
 * **Not handled yet**: `\0`, `\xNN`, `\uNNNN` hex/unicode escapes.
 */
@:re('"(?:[^"\\\\]|\\\\.)*"')
@:unescape
abstract HxDoubleStringLit(String) from String to String {}
