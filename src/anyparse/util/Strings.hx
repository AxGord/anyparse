package anyparse.util;

import StringTools.fastCodeAt;

using StringTools;

/** The text on either side of a delimiter. */
typedef Split = {
	final before: String;
	final after: String;
}

/**
 * The one answer to "how does the project read a piece of plain text": the line a position sits on, whether a string is
 * blank, whether it is an identifier, a quoted literal of it, where a
 * quoted literal ends, whether one pair of parentheses wraps all of it, and the part of it before or after a delimiter. A
 * delimiter is always a non-empty string. Where the delimiter is missing, the plain form returns the input unchanged
 * (nothing to cut) and the `OrNull` form returns null, so the caller who needs the difference asks for it by name. This
 * package imports nothing from `anyparse.*`, and it holds no state.
 */
final class Strings {

	/**
	 * Start offset of the line holding `at`, where a position on a `\n`
	 * belongs to the line that ends there; `at` is clamped to the text.
	 */
	public static function lineStart(source: String, at: Int): Int {
		var i: Int = at < source.length ? at : source.length;
		while (i > 0 && fastCodeAt(source, i - 1) != '\n'.code) i--;
		return i < 0 ? 0 : i;
	}

	/** 1-based number of the line holding `at`, counting only `\n`; `at` is clamped to the text. */
	public static function lineOf(source: String, at: Int): Int {
		final end: Int = at < source.length ? at : source.length;
		var line: Int = 1;
		for (i in 0...end) if (fastCodeAt(source, i) == '\n'.code) line++;
		return line;
	}

	/** Text before the first `\n`, without the `\r` of a CRLF break; the whole text, a trailing `\r` included, when it has no `\n`. */
	public static function firstLine(text: String): String {
		final nl: Int = text.indexOf('\n');
		if (nl < 0) return text;
		final end: Int = nl > 0 && fastCodeAt(text, nl - 1) == '\r'.code ? nl - 1 : nl;
		return text.substring(0, end);
	}

	/** Whether every character is white space (the set `StringTools.trim` strips); the empty text is blank. */
	public static function isBlank(text: String): Bool {
		for (i in 0...text.length) {
			final c: Int = fastCodeAt(text, i);
			if (c != ' '.code && (c < '\t'.code || c > '\r'.code)) return false;
		}
		return true;
	}

	/** Whether `c` can start an ASCII identifier: a letter or `_`. */
	public static function isIdentStart(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	/** Whether `c` can continue an ASCII identifier: an identifier start or a digit. */
	public static function isIdentChar(c: Int): Bool {
		return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
	}

	/** Whether `text` is one non-empty ASCII identifier. */
	public static function isIdentifier(text: String): Bool {
		if (text.length == 0 || !isIdentStart(fastCodeAt(text, 0))) return false;
		for (i in 1...text.length) if (!isIdentChar(fastCodeAt(text, i))) return false;
		return true;
	}

	/** `text` as a double-quoted string literal that is also a valid JSON string; characters above ASCII are kept as they are. */
	public static function quote(text: String): String {
		final out: StringBuf = new StringBuf();
		out.addChar('"'.code);
		for (i in 0...text.length) {
			final c: Int = fastCodeAt(text, i);
			switch c {
				case '"'.code:
					out.add('\\"');
				case '\\'.code:
					out.add('\\\\');
				case '\n'.code:
					out.add('\\n');
				case '\r'.code:
					out.add('\\r');
				case '\t'.code:
					out.add('\\t');
				case '\x08'.code:
					out.add('\\b');
				case '\x0C'.code:
					out.add('\\f');
				case _ if (c < ' '.code):
					out.add('\\u00${c.hex(2).toLowerCase()}');
				case _:
					out.addChar(c);
			}
		}
		out.addChar('"'.code);
		return out.toString();
	}

	/** Number of characters `c` in `text`. */
	public static function charCount(text: String, c: Int): Int {
		var n: Int = 0;
		for (i in 0...text.length) if (fastCodeAt(text, i) == c) n++;
		return n;
	}

	/** Text before the first `delimiter`, or null when there is none. */
	public static function allBeforeOrNull(text: String, delimiter: String): Null<String> {
		final at: Int = text.indexOf(delimiter);
		return at < 0 ? null : text.substring(0, at);
	}

	/** Text before the first `delimiter`; `text` itself when there is none. */
	public static function allBefore(text: String, delimiter: String): String {
		return allBeforeOrNull(text, delimiter) ?? text;
	}

	/** Text after the first `delimiter`, or null when there is none. */
	public static function allAfterOrNull(text: String, delimiter: String): Null<String> {
		final at: Int = text.indexOf(delimiter);
		return at < 0 ? null : text.substring(at + delimiter.length);
	}

	/** Text after the first `delimiter`; `text` itself when there is none. */
	public static function allAfter(text: String, delimiter: String): String {
		return allAfterOrNull(text, delimiter) ?? text;
	}

	/** Text after the last `delimiter`, or null when there is none. */
	public static function allAfterLastOrNull(text: String, delimiter: String): Null<String> {
		final at: Int = text.lastIndexOf(delimiter);
		return at < 0 ? null : text.substring(at + delimiter.length);
	}

	/** Text after the last `delimiter`; `text` itself when there is none. */
	public static function allAfterLast(text: String, delimiter: String): String {
		return allAfterLastOrNull(text, delimiter) ?? text;
	}

	/** `text` cut at its first `delimiter`, or null when there is none. */
	public static function firstSplit(text: String, delimiter: String): Null<Split> {
		final at: Int = text.indexOf(delimiter);
		return at < 0 ? null : { before: text.substring(0, at), after: text.substring(at + delimiter.length) };
	}

	/** `text` cut at its last `delimiter`, or null when there is none. */
	public static function lastSplit(text: String, delimiter: String): Null<Split> {
		final at: Int = text.lastIndexOf(delimiter);
		return at < 0 ? null : { before: text.substring(0, at), after: text.substring(at + delimiter.length) };
	}

	/** Text between the first `open` and the first `close` after it, or null when either is missing. */
	public static function extract(text: String, open: String, close: String): Null<String> {
		final from: Int = text.indexOf(open);
		if (from < 0) return null;
		final start: Int = from + open.length;
		final to: Int = text.indexOf(close, start);
		return to < 0 ? null : text.substring(start, to);
	}

	/**
	 * The index just past the string literal opening at `at` (its first character is the quote), or `at` when the
	 * literal is unterminated on its line. A backslash escape is stepped over, but never over a line break: a text that
	 * is a single-line tail must not let a dangling backslash carry the scan into the next line.
	 */
	public static function quotedEnd(source: String, at: Int): Int {
		final quote: Int = fastCodeAt(source, at);
		var i: Int = at + 1;
		while (i < source.length) {
			final c: Int = fastCodeAt(source, i);
			if (c == '\n'.code || c == '\r'.code) return at;
			if (c == '\\'.code) {
				if (i + 1 >= source.length || fastCodeAt(source, i + 1) == '\n'.code || fastCodeAt(source, i + 1) == '\r'.code) return at;
				i += 2;
				continue;
			}
			if (c == quote) return i + 1;
			i++;
		}
		return at;
	}

	/**
	 * The index of the `}` closing the `{` at `open` over the `length` codes `codeAt` reads, or -1 when it never closes.
	 * Braces count naively, the way the compiler's `${ … }` scanner counts them: a brace inside a nested string still
	 * counts. The one answer to "where does an interpolation block end".
	 */
	public static function closingBrace(length: Int, codeAt: Int -> Int, open: Int): Int {
		var depth: Int = 0;
		for (i in open ... length) {
			final c: Int = codeAt(i);
			if (c == '{'.code)
				depth++;
			else if (c == '}'.code && --depth == 0)
				return i;
		}
		return -1;
	}

	/**
	 * Whether `text` is one pair of parentheses around all of it: the `(` it opens with is closed by its last
	 * character. `(a)+(b)` and an unclosed `(()` are not; text inside quotes or comments counts like any other.
	 */
	public static function wrappedInParens(text: String): Bool {
		if (text.length < 2 || fastCodeAt(text, 0) != '('.code) return false;
		final last: Int = text.length - 1;
		var depth: Int = 0;
		for (i in 0...text.length) {
			final c: Int = fastCodeAt(text, i);
			if (c == '('.code)
				depth++;
			else if (c == ')'.code && --depth == 0)
				return i == last;
		}
		return false;
	}

	/** `text` without the pairs of parentheses wrapping all of it, white space inside each pair trimmed: `( (sys) )` reads as `sys`. */
	public static function stripOuterParens(text: String): String {
		var t: String = text;
		while (wrappedInParens(t)) t = t.substring(1, t.length - 1).trim();
		return t;
	}

}
