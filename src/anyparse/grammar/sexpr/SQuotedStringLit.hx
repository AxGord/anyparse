package anyparse.grammar.sexpr;

/**
 * Quoted-string terminal for S-expressions. The macro-generated writer
 * wraps the underlying `String` in double quotes and routes each code
 * point through `SExprFormat.escapeChar`. Use for `kind` / `name`
 * tokens that contain whitespace, parens, or quotes.
 *
 * The `@:re` pattern exists to satisfy the macro pipeline's
 * ShapeBuilder when this terminal is referenced from an `@:peg` enum.
 */
@:re('"(?:[^"\\\\]|\\\\.)*"')
@:unescape
abstract SQuotedStringLit(String) from String to String {}
