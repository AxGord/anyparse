package anyparse.grammar.haxe;

/**
 * Integer literal terminal for the Haxe grammar.
 *
 * Matches a positive decimal integer with optional digit separators
 * (`_`) and optional typed suffix (Haxe 5: `i8`/`i16`/`i32`/`i64`/
 * `u8`/`u16`/`u32`/`u64`, optionally underscore-separated). Examples:
 * `1`, `42`, `1_000_000`, `12_0i32`, `1_2_0_i32`. A leading `-` is a
 * unary operator and belongs to the expression grammar — it is NOT
 * part of the numeric terminal.
 *
 * Underscores are allowed BETWEEN digits only: the regex
 * `[0-9](?:_?[0-9])*` enforces a digit at both ends of the digit run,
 * so `_12` (leading underscore) and `12_` (trailing underscore with
 * no digit-or-suffix after) fail to match the full token; the latter
 * matches as `12` and leaves `_` for the next token.
 *
 * Source bytes are stored verbatim under `@:rawString` so the literal
 * round-trips byte-perfect — `1_000_000i32` survives intact rather
 * than being normalised to `1000000` via `Std.parseInt`. The `@:to
 * Int` conversion strips `_` and any trailing typed suffix before
 * `Std.parseInt` so tests can still destructure `IntLit(v)` and
 * assert with `(v : Int)`. Same source-verbatim contract as
 * `HxHexLit` / `HxFloatLit`.
 *
 * Float-shaped literals (`12.0`, `1e10`, `12f64`) belong to
 * `HxFloatLit` and are declared before this rule in `HxExpr` so the
 * float regex catches the leading-dot / exp / f-suffix forms; bare
 * digit runs (`42`) fall through to this rule.
 */
@:re('[0-9](?:_?[0-9])*(?:_?(?:i8|i16|i32|i64|u8|u16|u32|u64))?')
@:rawString
@:writeNormalize('stripSuffixUnderscore')
abstract HxIntLit(String) from String to String {

	@:to public function toInt(): Int {
		var s: String = StringTools.replace(this, '_', '');
		var i: Int = s.length;
		while (i > 0) {
			final c: Int = s.charCodeAt(i - 1);
			if (c >= '0'.code && c <= '9'.code) break;
			i--;
		}
		final parsed: Null<Int> = Std.parseInt(s.substr(0, i));
		return parsed == null ? 0 : parsed;
	}

}
