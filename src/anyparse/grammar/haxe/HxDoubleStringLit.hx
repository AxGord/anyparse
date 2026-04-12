package anyparse.grammar.haxe;

/**
 * Double-quoted Haxe string literal terminal.
 *
 * Matches a complete `"..."` string including the surrounding quotes.
 * Escape sequences (`\"`, `\\`, `\n`, `\r`, `\t`) are decoded at
 * runtime by `HxStringDecoder.decode` via the `@:decode` metadata.
 *
 * A separate type from `HxSingleStringLit` so the AST preserves which
 * quote style the source used — needed for round-trip writers.
 *
 * `from String to String` keeps test assertion literals compiling
 * without explicit casts.
 *
 * **Not handled yet**: `\0`, `\xNN`, `\uNNNN` hex/unicode escapes.
 */
@:re('"(?:[^"\\\\]|\\\\.)*"')
@:decode('anyparse.grammar.haxe.HxStringDecoder.decode')
abstract HxDoubleStringLit(String) from String to String {}
