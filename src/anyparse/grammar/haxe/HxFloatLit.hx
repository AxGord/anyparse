package anyparse.grammar.haxe;

/**
 * Floating-point literal terminal for the Haxe grammar.
 *
 * Matches a decimal number with a mandatory fractional part and an
 * optional exponent: `3.14`, `1.0e10`, `1.0E-3`. The mandatory `.` is
 * what distinguishes this terminal from `HxIntLit` — the branch order
 * inside `HxExpr` puts `FloatLit` before `IntLit` so a whole `3.14`
 * is matched as one float; for a bare `42` the float regex fails on
 * the missing `.` and the enum-branch try/catch wrapper rolls back
 * to `IntLit` which consumes the digits normally.
 *
 * Pure-integer forms like `3.` and `.14`, hex / octal / binary
 * literals, and digit separators (`1_000.0`) are all deferred — they
 * are Haxe-4 niceties with no current consumer in the test corpus.
 * When the first grammar needs them, extend the regex and revisit.
 *
 * The underlying type is `Float`, decoded via `Std.parseFloat` by
 * `Lowering.lowerTerminal`'s existing `Float` decoder row — no new
 * row is needed. `from Float to Float` keeps test literals like
 * `1.5` compiling without explicit casts.
 */
@:re('[0-9]+\\.[0-9]+(?:[eE][-+]?[0-9]+)?')
abstract HxFloatLit(Float) from Float to Float {}
