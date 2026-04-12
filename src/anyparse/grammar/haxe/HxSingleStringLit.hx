package anyparse.grammar.haxe;

/**
 * Single-quoted Haxe string literal terminal.
 *
 * Matches a complete `'...'` string including the surrounding quotes.
 * Escape sequences (`\'`, `\\`, `\n`, `\r`, `\t`) are decoded at
 * runtime by `HxStringDecoder.decode` via the `@:decode` metadata.
 *
 * A separate type from `HxDoubleStringLit` so the AST preserves which
 * quote style the source used — needed for round-trip writers.
 *
 * `from String to String` keeps test assertion literals compiling
 * without explicit casts.
 *
 * **Not handled yet**: string interpolation (`$var`, `${expr}`),
 * `\0`, `\xNN`, `\uNNNN` hex/unicode escapes.
 */
@:re("'(?:[^'\\\\]|\\\\.)*'")
@:decode('anyparse.grammar.haxe.HxStringDecoder.decode')
abstract HxSingleStringLit(String) from String to String {}
