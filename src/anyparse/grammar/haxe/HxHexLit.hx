package anyparse.grammar.haxe;

/**
 * Haxe hexadecimal integer-literal terminal.
 *
 * Matches `0x` / `0X` followed by hex digits with optional underscore
 * separators (`_`) and optional Haxe 5 typed integer suffix
 * (`i8`/`i16`/`i32`/`i64`/`u8`/`u16`/`u32`/`u64`, optionally
 * underscore-separated). Examples: `0x20`, `0XFF`, `0xDE_AD_BE_EF`,
 * `0x1_2_0i32`. Underscores are allowed BETWEEN hex digits only —
 * same digit-on-both-ends rule as `HxIntLit`.
 *
 * `@:rawString` stores the matched slice VERBATIM so the literal
 * round-trips byte-perfect — `0x20` and `0xDE_AD_BE_EF_i32` survive
 * intact rather than being normalised to `32` / `3735928559_i32`.
 * Same source-verbatim contract as `HxRegexLit` /
 * `HxDoubleStringLit`; value decode is deferred to a later analysis
 * pass that needs it.
 *
 * Declared before `IntLit` in `HxExpr`: the integer terminal `[0-9]…`
 * would otherwise match the leading `0` and stop, leaving `x20`
 * unconsumed. Hex has no fractional or exponent form, so it never
 * competes with `HxFloatLit`. Binary (`0b...`) is deferred until a
 * grammar requires it.
 */
@:re('0[xX][0-9A-Fa-f](?:_?[0-9A-Fa-f])*(?:_?(?:i8|i16|i32|i64|u8|u16|u32|u64))?')
@:rawString
@:writeNormalize('stripSuffixUnderscore')
abstract HxHexLit(String) from String to String {}
