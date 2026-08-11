package anyparse.grammar.haxe;

using StringTools;

/**
 * One character a string literal's RAW inner source spells: the `code` Haxe's
 * lexer decodes it to, and the `[from, to)` raw offsets of the spelling that
 * produced it — one byte for a plain character, two for `\n` / `\\` / `\'`,
 * four for `\xNN`, six for `\uNNNN`, and however many the braces of a `\u{…}`
 * span. A codepoint above `0xFFFF` is reported as ONE entry carrying the full
 * code; no consumer here needs the surrogate pair it becomes at runtime.
 */
typedef HxDecodedChar = {
	var code: Int;
	var from: Int;
	var to: Int;
}

/**
 * The escape DECODER `HxStringLitSegment` and `HxDoubleStringLit` promise in
 * their docs ("a consumer needing the decoded runtime value must call a decoder
 * helper"). Both terminals store their slice verbatim (`@:rawString`) so the
 * writer reproduces the author's spelling byte-for-byte; every consumer that
 * needs the VALUE those bytes denote comes through here.
 *
 * The one fact it exists for: Haxe decodes a literal's escapes BEFORE it scans a
 * single-quoted literal for interpolation, so `\x24`, `$` and `\u{24}` are
 * alternative SPELLINGS of the interpolation trigger `$`. `'\x24a'` is the value
 * of the local `a`, not the text `$a`; `'\x24{a}'` is `${a}`; `'\x24\x24a'` is
 * the escaped-dollar text `$a`. Decoding is a single pass, so a `\x5C` decoding
 * to a backslash does NOT then start a second escape (`'\x5Cx24a'` is the eight
 * characters `\x24a`). All verified by compile-and-run on `--interp` and `-js`.
 *
 * A scan that reads the RAW bytes therefore sees a plain literal exactly where
 * the compiler sees interpolation — the blindness this module closes for its two
 * callers: `HxInterpProjection` (the query tree's model of a single-quoted
 * literal) and `HaxeStringFoldSupport` (moving a double-quoted literal's raw
 * content into a single-quoted context).
 *
 * Braces are NOT decoded to triggers on their own: `'\x7Ba\x7D'` is the text
 * `{a}`. Only a `$` opens interpolation, so `$` is the only decoded character
 * this module hunts.
 */
@:nullSafety(Strict)
final class HxStringEscape {

	/** The interpolation trigger the decoded text is scanned for. */
	public static inline final DOLLAR: Int = "$".code;

	private static inline final BACKSLASH: Int = '\\'.code;

	/** Length of a `\X` escape — the backslash and the tag character that names it. */
	private static inline final TAG_LENGTH: Int = 2;

	/** Hexadecimal digits a `\xNN` escape spells its code point with. */
	private static inline final HEX_DIGITS: Int = 2;

	/** Hexadecimal digits a braceless `\uNNNN` escape spells its code point with. */
	private static inline final UNICODE_DIGITS: Int = 4;

	/** Offset from a `\u{N…}` escape's backslash to the first digit of its body (past `\`, `u` and `{`). */
	private static inline final BRACED_BODY_OFFSET: Int = 3;

	/** The largest code point a `\u{N…}` escape may name — the compiler's own `\u{10FFFF}` ceiling. */
	private static inline final MAX_CODE_POINT: Int = 0x10FFFF;

	private static inline final HEX_BASE: Int = 16;

	/** The value the first hexadecimal LETTER digit (`a` / `A`) stands for. */
	private static inline final HEX_LETTER_BASE: Int = 10;

	/**
	 * Whether the text `raw` decodes to carries a `$` — spelled raw, or through an
	 * escape (`\x24`, `$`, `\u{24}`). The question a caller that copies `raw`
	 * VERBATIM into a single-quoted context asks. The cheap pre-test is exact: a `$`
	 * can only arrive as itself or out of a backslash escape.
	 */
	public static function carriesDollar(raw: String): Bool {
		return (raw.indexOf("$") >= 0 || raw.indexOf('\\') >= 0) && carries(raw, false);
	}

	/**
	 * Whether an ESCAPE in `raw` decodes to a `$` — the narrower question a caller that
	 * re-escapes raw `$`s itself asks, since only the escape-spelled one is beyond its
	 * reach (`"a$b"` re-escapes to `a$$b`; `"a\x24b"` cannot, short of rewriting the
	 * escape). Also the trigger for `HxInterpProjection`, whose input is a `Literal`
	 * fragment that by construction holds no raw `$`.
	 */
	public static function carriesEscapedDollar(raw: String): Bool {
		return raw.indexOf('\\') >= 0 && carries(raw, true);
	}

	/**
	 * The code of the FIRST character `raw` decodes to, or -1 when it is empty. What a
	 * caller peeking at the text that will follow a `$name` needs: `\x41b` starts with an
	 * `A`, not with a backslash, and an `A` would extend the interpolated name.
	 */
	public static function firstCode(raw: String): Int {
		return raw.length == 0 ? -1 : charAt(raw, 0).code;
	}

	/** `raw` decoded character by character, each entry keeping the raw offsets of its spelling. */
	public static function decode(raw: String): Array<HxDecodedChar> {
		final out: Array<HxDecodedChar> = [];
		var i: Int = 0;
		while (i < raw.length) {
			final c: HxDecodedChar = charAt(raw, i);
			out.push(c);
			i = c.to;
		}
		return out;
	}

	/**
	 * Whether `code` starts a Haxe identifier (a letter or an underscore) — the test that
	 * decides whether a `$` begins the `$name` shorthand. Shared with the `$name`
	 * lookahead in `HaxeStringFoldSupport`: the two ends of one feature must not drift
	 * apart on what a name is.
	 */
	public static function isIdentStart(code: Int): Bool {
		return code >= 'a'.code && code <= 'z'.code || code >= 'A'.code && code <= 'Z'.code || code == '_'.code;
	}

	/** Whether `code` continues a Haxe identifier (a letter, a digit, or an underscore). */
	public static function isIdentContinue(code: Int): Bool {
		return isIdentStart(code) || code >= '0'.code && code <= '9'.code;
	}

	/**
	 * The one character `raw` spells at `i`. A backslash opens an escape: `\xNN` and
	 * `\uNNNN` / `\u{N…}` decode their hex digits, `\n` / `\r` / `\t` their control
	 * character, and every other two-character form decodes to the character after
	 * the backslash — which is what `\\`, `\'` and `\"` need and what an INVALID
	 * escape (`\X24`, rejected by the compiler) harmlessly falls back to.
	 *
	 * Public because the SPAN is the answer as often as the code is: a scan that walks a
	 * raw literal cannot advance by a fixed number of characters without landing inside a
	 * `\u{…}` body, whose braces then read as ordinary text. `HaxeStringFoldSupport.scanCuts`
	 * is that caller — the escape lengths live here, and nowhere else. `i` must be a valid
	 * index into `raw`.
	 */
	public static function charAt(raw: String, i: Int): HxDecodedChar {
		final c: Int = raw.fastCodeAt(i);
		if (c != BACKSLASH || i + 1 >= raw.length) return { code: c, from: i, to: i + 1 };
		final body: Int = i + TAG_LENGTH;
		final tag: Int = raw.fastCodeAt(i + 1);
		return if (tag == 'x'.code)
			hexEscape(raw, i, body, HEX_DIGITS)
		else if (tag == 'u'.code)
			body < raw.length && raw.fastCodeAt(body) == '{'.code ? bracedEscape(raw, i) : hexEscape(raw, i, body, UNICODE_DIGITS)
		else if (tag == 'n'.code)
			{ code: '\n'.code, from: i, to: body }
		else if (tag == 'r'.code)
			{ code: '\r'.code, from: i, to: body }
		else if (tag == 't'.code)
			{ code: '\t'.code, from: i, to: body }
		else
			{ code: tag, from: i, to: body };
	}

	/** Whether any decoded character of `raw` is a `$`, counting only escape-spelled ones when `escapedOnly`. */
	private static function carries(raw: String, escapedOnly: Bool): Bool {
		var i: Int = 0;
		while (i < raw.length) {
			final c: HxDecodedChar = charAt(raw, i);
			if (c.code == DOLLAR && (!escapedOnly || c.to - c.from > 1)) return true;
			i = c.to;
		}
		return false;
	}

	/**
	 * The `\xNN` / `\uNNNN` form starting at `from`, its `count` hex digits read from
	 * `at`. A truncated or non-hex run is no escape the compiler accepts, so it falls
	 * back to the two-character reading — the `x` / `u` itself, which is never a `$`.
	 */
	private static function hexEscape(raw: String, from: Int, at: Int, count: Int): HxDecodedChar {
		if (at + count > raw.length) return tagOnly(raw, from);
		var code: Int = 0;
		for (k in at ... at + count) {
			final digit: Int = hexDigit(raw.fastCodeAt(k));
			if (digit < 0) return tagOnly(raw, from);
			code = code * HEX_BASE + digit;
		}
		return { code: code, from: from, to: at + count };
	}

	/**
	 * The `\u{N…}` form starting at `from`. An unclosed, empty or non-hex body is no
	 * escape the compiler accepts and falls back to the two-character reading, as in
	 * `hexEscape`.
	 *
	 * The body has NO digit limit — `\u{0000024}` is seven digits and the compiler
	 * accepts it as a `$` (verified by running), so counting digits would silently miss
	 * a trigger, the one direction that costs a value change. Accumulation instead stops
	 * once the value passes the compiler's own `\u{10FFFF}` ceiling: such a code point is
	 * rejected by the compiler anyway, and freezing it there keeps it away from `Int`
	 * overflow, whose wrapped value is target-dependent and could land back on a `$`.
	 */
	private static function bracedEscape(raw: String, from: Int): HxDecodedChar {
		var code: Int = 0;
		var digits: Int = 0;
		var k: Int = from + BRACED_BODY_OFFSET;
		while (k < raw.length) {
			final c: Int = raw.fastCodeAt(k);
			if (c == '}'.code) return digits == 0 ? tagOnly(raw, from) : { code: code, from: from, to: k + 1 };
			final digit: Int = hexDigit(c);
			if (digit < 0) break;
			if (code <= MAX_CODE_POINT) code = code * HEX_BASE + digit;
			digits++;
			k++;
		}
		return tagOnly(raw, from);
	}

	/** The fallback reading of a malformed escape at `from`: its two characters, decoding to the tag itself. */
	private static function tagOnly(raw: String, from: Int): HxDecodedChar {
		return { code: raw.fastCodeAt(from + 1), from: from, to: from + TAG_LENGTH };
	}

	/** `code`'s value as a hexadecimal digit, or -1 when it is not one. */
	private static function hexDigit(code: Int): Int {
		return if (code >= '0'.code && code <= '9'.code)
			code - '0'.code
		else if (code >= 'a'.code && code <= 'f'.code)
			code - 'a'.code + HEX_LETTER_BASE
		else if (code >= 'A'.code && code <= 'F'.code)
			code - 'A'.code + HEX_LETTER_BASE
		else
			-1;
	}

}
