package anyparse.grammar.json;

using StringTools;

/**
 * The one answer to "how is one string spelled as a JSON string". A plain class with no import, so `haxe --macro` can run it
 * (it refuses a `@:build` type) and a compile's probe directory can carry it alone: the macro side's door to JSON text.
 */
@:nullSafety(Strict)
final class JsonText {

	/** JSON string-escape char code for backspace (`\b`). */
	private static inline final BACKSPACE: Int = 0x08;

	/** JSON string-escape char code for form feed (`\f`). */
	private static inline final FORM_FEED: Int = 0x0C;

	/** The first high surrogate; the low ones start where the high ones end. */
	private static inline final HIGH_SURROGATE: Int = 0xD800;

	private static inline final LOW_SURROGATE: Int = 0xDC00;
	private static inline final LAST_SURROGATE: Int = 0xDFFF;

	/**
	 * `text` as one JSON string, quotes included. A lone surrogate keeps its escape: output is UTF-8, which cannot carry
	 * one, and written bare it would come back as a different character. On js the engine's own writer spells exactly
	 * these bytes.
	 */
	public static function quote(text: String): String {
		#if js
		return js.Syntax.code('JSON.stringify({0})', text);
		#else
		// a run that needs no escape is copied whole: one character at a time costs a string per character
		final out: StringBuf = new StringBuf();
		out.addChar('"'.code);
		var start: Int = 0;
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			final lone: Bool = c >= HIGH_SURROGATE && c <= LAST_SURROGATE && isLoneSurrogate(text, i, c);
			if (c >= ' '.code && c != '"'.code && c != '\\'.code && !lone) continue;
			out.addSub(text, start, i - start);
			out.add(lone ? unicodeEscape(c) : escapeChar(c));
			start = i + 1;
		}
		out.addSub(text, start, text.length - start);
		out.addChar('"'.code);
		return out.toString();
		#end
	}

	/** The spelling of the code unit `c` inside a JSON string. */
	public static function escapeChar(c: Int): String {
		return switch c {
			case '"'.code: '\\"';
			case '\\'.code: '\\\\';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case BACKSPACE: '\\b';
			case FORM_FEED: '\\f';
			case _:
				c < ' '.code ? unicodeEscape(c) : String.fromCharCode(c);
		};
	}

	private static inline function isLow(c: Int): Bool {
		return c >= LOW_SURROGATE && c <= LAST_SURROGATE;
	}

	/** The `\uXXXX` escape of `c`, in the lower case every native JSON writer spells it in. */
	private static inline function unicodeEscape(c: Int): String {
		return '\\u${c.hex(4).toLowerCase()}';
	}

	/** Whether the code unit `c` at `i` of `text` is half of a surrogate pair with no other half beside it. */
	private static function isLoneSurrogate(text: String, i: Int, c: Int): Bool {
		return c >= HIGH_SURROGATE && c < LOW_SURROGATE
			? i + 1 >= text.length || !isLow(text.fastCodeAt(i + 1))
			: isLow(c) && (i == 0 || text.fastCodeAt(i - 1) < HIGH_SURROGATE || text.fastCodeAt(i - 1) >= LOW_SURROGATE);
	}

}
