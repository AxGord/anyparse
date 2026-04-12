package anyparse.grammar.haxe;

import anyparse.format.text.TextFormat.UnescapeResult;

/**
 * Decodes a Haxe string literal (both single- and double-quoted).
 *
 * Strips the surrounding quote characters and unescapes `\X` sequences
 * via `HaxeFormat.instance.unescapeChar`. The function is quote-agnostic:
 * it strips the first and last character unconditionally, so it works
 * for both `"..."` and `'...'` literals.
 *
 * Named by terminal abstracts via `@:decode` metadata so the macro
 * pipeline calls this at runtime instead of the JSON-specific decoder.
 *
 * **Not handled yet**: `\0`, `\xNN`, `\uNNNN` hex/unicode escapes.
 */
@:nullSafety(Strict)
final class HxStringDecoder {

	public static function decode(raw:String):String {
		final body:String = raw.substring(1, raw.length - 1);
		final buf:StringBuf = new StringBuf();
		var i:Int = 0;
		while (i < body.length) {
			final c:Int = StringTools.fastCodeAt(body, i);
			if (c == '\\'.code) {
				final res:UnescapeResult = HaxeFormat.instance.unescapeChar(body, i + 1);
				buf.addChar(res.char);
				i += 1 + res.consumed;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return buf.toString();
	}

	/**
	 * Decode a run of literal characters and escape sequences inside a
	 * single-quoted string. Unlike `decode`, does NOT strip surrounding
	 * quote characters — the input is already the body segment matched
	 * by the `HxStringLitSegment` regex.
	 *
	 * Processes `\X` escape sequences via `HaxeFormat.instance.unescapeChar`;
	 * passes all other characters through unchanged.
	 *
	 * Named by `HxStringLitSegment` via `@:decode` metadata.
	 */
	public static function decodeLiteral(raw:String):String {
		final buf:StringBuf = new StringBuf();
		var i:Int = 0;
		while (i < raw.length) {
			final c:Int = StringTools.fastCodeAt(raw, i);
			if (c == '\\'.code) {
				final res:UnescapeResult = HaxeFormat.instance.unescapeChar(raw, i + 1);
				buf.addChar(res.char);
				i += 1 + res.consumed;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return buf.toString();
	}
}
