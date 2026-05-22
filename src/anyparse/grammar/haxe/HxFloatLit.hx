package anyparse.grammar.haxe;

/**
 * Floating-point literal terminal for the Haxe grammar.
 *
 * Matches three shapes:
 *   - `3.14`, `1.0e10`, `1.0E-3` — full form (digits, `.`, digits,
 *     optional exponent).
 *   - `1.`, `5.` — trailing-dot form (digits, `.`, no following
 *     digits). The negative lookahead `(?![\w.])` keeps the match
 *     non-greedy on three otherwise-ambiguous prefixes:
 *       - `0...10` — Slice 4 interval operator (`...`); the second
 *         `.` cancels the float match so `0` parses as `IntLit` and
 *         `...10` as the infix range op.
 *       - `1.foo` — field access on an int literal; the trailing
 *         `f` cancels the match so `1` parses as `IntLit` and
 *         `.foo` as a postfix field access.
 *       - `1.5` — handled by the first alternative; the second is
 *         never reached for valid full-form floats.
 *
 * Underlying type is `String` with `@:rawString` so the literal
 * round-trips byte-perfect — `1.` survives as `1.`, not normalised
 * to `1.0` via `Std.string(1.0)`. Same source-verbatim contract as
 * `HxHexLit` / `HxRegexLit` / `HxDoubleStringLit`. The `@:to Float`
 * conversion lets tests destructure `FloatLit(v)` and assert with
 * `Assert.floatEquals(3.14, (v : Float))` — the cast triggers
 * `Std.parseFloat` on the stored string.
 *
 * Pure-decimal forms like `.14` (no leading digits), hex / octal /
 * binary literals, and digit separators (`1_000.0`) are still
 * deferred — no corpus consumer yet. The first grammar that needs
 * them extends the regex and adds the source-preservation already
 * in place here.
 *
 * Declared before `IntLit` in `HxExpr`: the integer terminal
 * `[0-9]+` would otherwise match the leading digits and stop, leaving
 * `.5` unconsumed. The float regex's negative lookahead ensures
 * trailing-dot matches do not over-consume past range operators or
 * field-access tokens (see above).
 *
 * Both alternatives are wrapped in a non-capturing group `(?:…|…)` so
 * the lowering's `^`-anchor (prepended by `Lit.lowerTerminal`) binds
 * the start position to both — not just the first alt. Without the
 * group `^A|B` means `(^A)|B`, and the second alt scans the rest of
 * input for a match starting anywhere, silently consuming the
 * subsequent `1.` mid-buffer when the position was actually at an
 * ident.
 */
@:re('(?:[0-9]+\\.[0-9]+(?:[eE][-+]?[0-9]+)?|[0-9]+\\.(?![\\w.]))')
@:rawString
abstract HxFloatLit(String) from String to String {
	@:to public inline function toFloat():Float return Std.parseFloat(this);
}
