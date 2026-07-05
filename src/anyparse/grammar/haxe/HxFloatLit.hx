package anyparse.grammar.haxe;

/**
 * Floating-point literal terminal for the Haxe grammar.
 *
 * Five shapes (in regex source order):
 *   - **Full** `[digits].[digits]([eE][±]?[digits])?` —
 *     `3.14`, `1.0e10`, `1.0E-3`. Optional Haxe 5 typed float suffix
 *     (`f32`/`f64`, optionally underscore-separated): `12.34f64`,
 *     `1.0_f32`.
 *   - **Trailing-dot** `[digits].` — `1.`, `5.`. The negative
 *     lookahead `(?![\w.])` keeps the match non-greedy on three
 *     otherwise-ambiguous prefixes:
 *       - `0...10` — Slice 4 interval operator (`...`); the second
 *         `.` cancels the float match so `0` parses as `IntLit` and
 *         `...10` as the infix range op.
 *       - `1.foo` — field access on an int literal; the trailing
 *         `f` cancels the match so `1` parses as `IntLit` and
 *         `.foo` as a postfix field access.
 *       - `1.5` — handled by the first alternative.
 *   - **Leading-dot** `.[digits]([eE][±]?[digits])?` — `.34`,
 *     `.5e3`. Optional `f32`/`f64` suffix.
 *   - **Exp-no-dot** `[digits][eE][±]?[digits]` — `1e3`, `12e34`.
 *     Optional `f32`/`f64` suffix.
 *   - **f-suffix-only** `[digits]f(?:32|64)` — `12f64`, `1_2f64`.
 *     Bare digits with a mandatory float-typed suffix; needed because
 *     suffix alone (no `.`, no `e`) is sufficient to mark the literal
 *     as float (Haxe 5 typed-suffix semantics).
 *
 * Digit runs accept underscore separators (`_`) between adjacent
 * digits — `[0-9](?:_?[0-9])*` — matching `HxIntLit` / `HxHexLit`
 * with the same digit-on-both-ends rule. Source bytes are stored
 * verbatim under `@:rawString` so `1_2.3_4f64` round-trips intact;
 * the `@:to Float` conversion strips `_` and any `f32`/`f64` suffix
 * before `Std.parseFloat` so tests can still destructure
 * `FloatLit(v)` and assert with `(v : Float)`.
 *
 * Same source-verbatim contract as `HxHexLit` / `HxRegexLit` /
 * `HxDoubleStringLit`. Declared before `IntLit` in `HxExpr` so the
 * float regex catches the leading-dot / exp / f-suffix forms first;
 * bare digit runs without `_`/`./e/f` fall through to `IntLit`. The
 * integer-typed suffixes (`i32`/`u64`/…) are on `IntLit`, NOT here —
 * `12i32` is a typed int, not a float.
 *
 * All five alternatives are wrapped in a non-capturing group `(?:…)`
 * so the lowering's `^`-anchor (prepended by `Lit.lowerTerminal`)
 * binds the start position to every alt — not just the first.
 * Without the group `^A|B…` means `(^A)|B|…`, and the later alts
 * scan the rest of input for a match starting anywhere, silently
 * consuming subsequent numeric literals mid-buffer when the position
 * was actually at an ident.
 */
@:re('(?:[0-9](?:_?[0-9])*\\.[0-9](?:_?[0-9])*(?:[eE][-+]?[0-9](?:_?[0-9])*)?(?:_?f(?:32|64))?|[0-9](?:_?[0-9])*\\.(?![\\w.])|\\.[0-9](?:_?[0-9])*(?:[eE][-+]?[0-9](?:_?[0-9])*)?(?:_?f(?:32|64))?|[0-9](?:_?[0-9])*[eE][-+]?[0-9](?:_?[0-9])*(?:_?f(?:32|64))?|[0-9](?:_?[0-9])*_?f(?:32|64))')
@:rawString
@:writeNormalize('stripSuffixUnderscore')
abstract HxFloatLit(String) from String to String {

	@:to public inline function toFloat(): Float {
		var s: String = StringTools.replace(this, '_', '');
		if (StringTools.endsWith(s, 'f32'))
			s = s.substr(0, s.length - 3);
		else if (StringTools.endsWith(s, 'f64'))
			s = s.substr(0, s.length - 3);
		return Std.parseFloat(s);
	}

}
