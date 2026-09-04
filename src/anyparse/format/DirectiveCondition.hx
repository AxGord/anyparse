package anyparse.format;

using StringTools;

/**
 * Text normalisation for a conditional-compilation condition - the `#if` /
 * `#elseif` operand a grammar captures VERBATIM as one terminal.
 *
 * Such a condition is not an expression tree in this parser and deliberately is
 * not one: it is preprocessor input, its identifiers are build defines rather than
 * values, and the shapes it admits (`0`, a dotted path, `!!x`) are its own. So the
 * writer's operator-spacing knobs, which all act on operator NODES, have nothing
 * to act on here and the text has always been re-emitted byte-for-byte. This class
 * is the one place that changes it, on the one axis a config can ask for.
 *
 * Scope, stated as a refusal: only the BINARY `&&` and `||` are respaced. A `!` is
 * unary, and `around` spacing applied to it would emit `! js`, which no config
 * means to ask for; a config that wants that has to say so through a knob of its
 * own. Everything else in the text - parentheses, identifiers, comparison
 * operators, string literals - is copied through unchanged.
 *
 * Two fail-closed rules keep the transform from inventing a shape the author did
 * not write. A `"` / `'` literal is copied verbatim, so an operator INSIDE it is
 * never touched (`#if (haxe_ver >= "4||5")`). And an operator whose surrounding
 * whitespace holds a NEWLINE is left exactly as authored: a multi-line condition's
 * line breaks are the author's layout, and joining them onto one line is a
 * different decision from spacing an operator.
 */
@:nullSafety(Strict)
final class DirectiveCondition {

	/**
	 * `text` with every top-level `&&` / `||` respaced per `policy`; `text` itself
	 * when the policy is `Keep`, which is the default every config gets.
	 */
	public static function spaceOperators(text: String, policy: OperatorSpacing): String {
		if (policy == OperatorSpacing.Keep) return text;
		final n: Int = text.length;
		var out: String = '';
		var i: Int = 0;
		while (i < n) {
			final c: Int = text.fastCodeAt(i);
			if (c == '"'.code || c == "'".code) {
				final end: Int = literalEnd(text, i);
				out += text.substring(i, end);
				i = end;
				continue;
			}
			if (!isOperatorAt(text, i, n)) {
				out += text.charAt(i);
				i++;
				continue;
			}
			final lead: Int = trimmedEnd(out);
			var j: Int = i + 2;
			while (j < n && isBlank(text.fastCodeAt(j))) j++;
			// A newline on either side is the author's layout, not spacing - leave the
			// whole occurrence alone and resume after it.
			if (lead < 0 || hasNewline(text, i + 2, j)) {
				out += text.substring(i, i + 2);
				i += 2;
				continue;
			}
			final head: String = out.substring(0, lead);
			final tight: Bool = policy == OperatorSpacing.None;
			out = head + (tight || head.length == 0 ? '' : ' ') + text.substring(i, i + 2) + (tight || j >= n ? '' : ' ');
			i = j;
		}
		return out;
	}

	/** Whether a two-character `&&` / `||` starts at `i`. */
	private static inline function isOperatorAt(text: String, i: Int, n: Int): Bool {
		final c: Int = text.fastCodeAt(i);
		return (c == '|'.code || c == '&'.code) && i + 1 < n && text.fastCodeAt(i + 1) == c;
	}

	/** A space or a tab - the whitespace this transform owns. A newline is not one. */
	private static inline function isBlank(c: Int): Bool {
		return c == ' '.code || c == '\t'.code;
	}

	/**
	 * The index one past the closing quote of the literal starting at `open`, or
	 * `text.length` for an unterminated one. Backslash escapes are stepped over, so
	 * an escaped quote does not end the literal.
	 */
	private static function literalEnd(text: String, open: Int): Int {
		final quote: Int = text.fastCodeAt(open);
		final n: Int = text.length;
		var i: Int = open + 1;
		while (i < n) {
			final c: Int = text.fastCodeAt(i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			i++;
			if (c == quote) return i;
		}
		return n;
	}

	/**
	 * The length of `out` with its trailing spaces and tabs removed, or `-1` when a
	 * NEWLINE sits in that trailing run - the caller then leaves the occurrence alone.
	 */
	private static function trimmedEnd(out: String): Int {
		var k: Int = out.length;
		while (k > 0) {
			final c: Int = out.fastCodeAt(k - 1);
			if (c == '\n'.code || c == '\r'.code) return -1;
			if (!isBlank(c)) break;
			k--;
		}
		return k;
	}

	/** Whether `text[from...to]` holds a line break. */
	private static function hasNewline(text: String, from: Int, to: Int): Bool {
		for (i in from ... to) {
			final c: Int = text.fastCodeAt(i);
			if (c == '\n'.code || c == '\r'.code) return true;
		}
		return false;
	}

}
