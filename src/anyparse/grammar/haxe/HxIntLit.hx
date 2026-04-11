package anyparse.grammar.haxe;

/**
 * Integer literal terminal for the Haxe grammar.
 *
 * Matches a positive decimal integer (`[0-9]+`). A leading `-` is a
 * unary operator and belongs to the expression grammar once the Pratt
 * strategy lands — it is NOT part of the numeric terminal. Hex, octal,
 * and digit-separator forms (`0xff`, `0o17`, `1_000_000`) are deferred
 * until a grammar requires them.
 *
 * The underlying type is `Int`, decoded via `Std.parseInt` by
 * `Lowering.lowerTerminal`'s closed decoder table — the third row
 * added alongside `Float` and `String` (D20's exit trigger met by
 * this type's arrival). The decoder guards the `Null<Int>` return of
 * `Std.parseInt` with an explicit null check even though the regex
 * gate makes the null branch unreachable — defensive minimalism over
 * an unsafe coercion.
 *
 * `from Int to Int` keeps expected-value literals in tests compiling
 * without explicit casts — the abstract is fully transparent in
 * practice.
 */
@:re('[0-9]+')
abstract HxIntLit(Int) from Int to Int {}
