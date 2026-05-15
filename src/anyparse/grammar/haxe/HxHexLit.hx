package anyparse.grammar.haxe;

/**
 * Haxe hexadecimal integer-literal terminal.
 *
 * Matches `0x` / `0X` followed by one or more hex digits (`0x20`,
 * `0XFF`, `0xDEADBEEF`). `@:rawString` stores the matched slice
 * VERBATIM so the literal round-trips byte-perfect: decoding to `Int`
 * and re-emitting would normalise `0x20` to `32` and lose the
 * `0x`/`0X` case, an irreversible source-form change. Same
 * source-verbatim contract as `HxRegexLit` / `HxDoubleStringLit` —
 * value decode is deferred to a later analysis pass that needs it.
 *
 * Declared before `IntLit` in `HxExpr`: the integer terminal `[0-9]+`
 * would otherwise match the leading `0` and stop, leaving `x20`
 * unconsumed. Hex has no fractional or exponent form, so it never
 * competes with `HxFloatLit`. Digit-separator (`0xFF_FF`) and binary
 * (`0b...`) forms are deferred until a grammar requires them.
 *
 * `from String to String` keeps test assertion literals compiling
 * without explicit casts.
 */
@:re('0[xX][0-9A-Fa-f]+')
@:rawString
abstract HxHexLit(String) from String to String {}
