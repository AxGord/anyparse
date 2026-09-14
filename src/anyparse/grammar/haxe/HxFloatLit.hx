package anyparse.grammar.haxe;

using StringTools;

/**
 * Floating-point literal terminal for the Haxe grammar.
 *
 * Five shapes, in regex source order: **Full** `[digits].[digits]([eE][±]?[digits])?`
 * (`3.14`, `1.0E-3`) with an optional Haxe 5 typed suffix (`f32`/`f64`, optionally
 * underscore-separated: `12.34f64`, `1.0_f32`); **Trailing-dot** `[digits].` (`1.`), where the
 * negative lookahead `(?![\w.])` cancels the match on `0...10` (so `0` is an `IntLit` and
 * `...` the interval operator) and on `1.foo` (so `1` is an `IntLit` and `.foo` a postfix
 * field access); **Leading-dot** `.[digits]([eE][±]?[digits])?` (`.34`, `.5e3`);
 * **Exp-no-dot** `[digits][eE][±]?[digits]` (`1e3`); and **f-suffix-only** `[digits]f(?:32|64)`
 * (`12f64`) — a typed suffix alone marks the literal as float under Haxe 5 semantics. The
 * last three take the optional `f32`/`f64` suffix too.
 *
 * Digit runs accept underscore separators between adjacent digits — `[0-9](?:_?[0-9])*` —
 * matching `HxIntLit` / `HxHexLit` with the same digit-on-both-ends rule. Source bytes are
 * stored verbatim under `@:rawString` so `1_2.3_4f64` round-trips intact; the `@:to Float`
 * conversion strips `_` and any `f32`/`f64` suffix before `Std.parseFloat` so tests can still
 * destructure `FloatLit(v)` and assert with `(v : Float)`.
 *
 * Same source-verbatim contract as `HxHexLit` / `HxRegexLit` / `HxDoubleStringLit`. Declared
 * before `IntLit` in `HxExpr` so the float regex catches the leading-dot / exp / f-suffix
 * forms first; bare digit runs fall through to `IntLit`. The integer-typed suffixes
 * (`i32`/`u64`/…) are on `IntLit`, NOT here — `12i32` is a typed int.
 *
 * All five alternatives are wrapped in a non-capturing group `(?:…)` so the lowering's
 * `^`-anchor (prepended by `Lit.lowerTerminal`) binds the start position to every alt — not
 * just the first; `^A|B…` means `(^A)|B|…`, and the later alts would otherwise match a numeric
 * literal mid-buffer when the position was actually at an ident.
 */
@:re('(?:[0-9](?:_?[0-9])*\\.[0-9](?:_?[0-9])*(?:[eE][-+]?[0-9](?:_?[0-9])*)?(?:_?f(?:32|64))?|[0-9](?:_?[0-9])*\\.(?![\\w.])|\\.[0-9](?:_?[0-9])*(?:[eE][-+]?[0-9](?:_?[0-9])*)?(?:_?f(?:32|64))?|[0-9](?:_?[0-9])*[eE][-+]?[0-9](?:_?[0-9])*(?:_?f(?:32|64))?|[0-9](?:_?[0-9])*_?f(?:32|64))')
@:rawString
@:writeNormalize('stripSuffixUnderscore')
abstract HxFloatLit(String) from String to String {

	@:to public inline function toFloat(): Float {
		var s: String = this.replace('_', '');
		if (s.endsWith('f32'))
			s = s.substr(0, s.length - 3);
		else if (s.endsWith('f64'))
			s = s.substr(0, s.length - 3);
		return Std.parseFloat(s);
	}

}
