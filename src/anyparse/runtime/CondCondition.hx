package anyparse.runtime;

import anyparse.util.Strings;

using StringTools;

/**
 * The one answer to "where does a preprocessor `#if` condition end": `!`* and ONE operand (a
 * parenthesised group, a quoted string, a dotted flag name or a number). The query side's directive
 * reader and the generated parsers' splice predicates both read a condition here, so one `#if` is
 * one condition for a check and for the parser; it depends on nothing outside the runtime.
 */
@:nullSafety(Strict)
final class CondCondition {

	/**
	 * The condition span starting after a keyword at `from`, or null when the directive carries
	 * none. A line break continues the condition only after the keyword, after `!` and inside a
	 * parenthesised group. Outside parentheses Haxe reads `!`* and ONE operand, so a binary operator
	 * ends the condition on any line: the rest, on the same line or the next, is the region's body.
	 */
	public static function conditionAt(source: String, from: Int): Null<Span> {
		final start: Int = skipBlank(source, from);
		final end: Int = scanExpression(source, start);
		return end > start ? new Span(start, end) : null;
	}

	/**
	 * Where the leading `#if` operand of a spliced fragment ends, past the blank after it: the operand
	 * is `conditionAt`'s, so the parser's splice predicates and the query side read one condition. A
	 * fragment carrying no operand (a stray `)`, an unbalanced group) answers the end of the input.
	 */
	public static function skipConditionAtom(source: String, at: Int): Int {
		final atom: Null<Span> = conditionAt(source, at);
		return atom == null ? source.length : skipBlank(source, atom.to);
	}

	/** Whether `c` opens a string literal. */
	private static inline function isQuote(c: Int): Bool {
		return c == '"'.code || c == '\''.code;
	}

	/** Whether `c` ends a physical line. */
	private static inline function isLineBreak(c: Int): Bool {
		return c == '\n'.code || c == '\r'.code;
	}

	/** Whether `c` is an ASCII digit. */
	private static inline function isDigit(c: Int): Bool {
		return c >= '0'.code && c <= '9'.code;
	}

	/**
	 * The end of the conditional expression at `at`, or `at` when the text holds none.
	 *
	 * Outside parentheses Haxe reads optional `!` prefixes and ONE operand; a binary operator after
	 * it starts the region's body, not the condition (`#if lime && x` reads `lime`). Stopping there
	 * rather than at the end of the line is the whole point: a region may be written inline
	 * (`#if sys trace(1); #end`), where the tokens after the condition are ordinary code, and
	 * swallowing them would report — and let a fixer rewrite — a span that is not the directive.
	 */
	private static function scanExpression(source: String, at: Int): Int {
		var operand: Int = at;
		while (operand < source.length && source.fastCodeAt(operand) == '!'.code) operand = skipBlank(source, operand + 1);
		final operandEnd: Int = scanOperand(source, operand);
		return operandEnd > operand ? operandEnd : at;
	}

	/** The end of the single operand at `at` — a parenthesised group, a quoted string, an identifier or a number — or `at` when none. */
	private static function scanOperand(source: String, at: Int): Int {
		if (at >= source.length) return at;
		final c: Int = source.fastCodeAt(at);
		if (c == '('.code) return scanParens(source, at);
		if (isQuote(c)) return Strings.quotedEnd(source, at);
		if (Strings.isIdentStart(c)) return scanFlagName(source, at + 1);
		if (!isDigit(c)) return at;
		var i: Int = at + 1;
		while (i < source.length) {
			final digit: Int = source.fastCodeAt(i);
			if (!isDigit(digit) && digit != '.'.code) break;
			i++;
		}
		return i;
	}

	/** The index just past the `)` matching the `(` at `at`, or `at` when the group is unbalanced; a group may span lines. */
	private static function scanParens(source: String, at: Int): Int {
		var depth: Int = 0;
		var i: Int = at;
		while (i < source.length) {
			final c: Int = source.fastCodeAt(i);
			if (isQuote(c)) {
				final quoted: Int = Strings.quotedEnd(source, i);
				if (quoted <= i) return at;
				i = quoted;
				continue;
			}
			if (c == '('.code) {
				depth++;
			} else if (c == ')'.code) {
				depth--;
				if (depth == 0) return i + 1;
			}
			i++;
		}
		return at;
	}

	/** The index of the first character at or after `at` that is not whitespace, line breaks included. */
	private static function skipBlank(source: String, at: Int): Int {
		var i: Int = at;
		while (i < source.length) {
			final c: Int = source.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code && !isLineBreak(c)) return i;
			i++;
		}
		return i;
	}

	/**
	 * The end of the identifier operand whose first character sits at `from - 1`. A define name may
	 * be DOTTED (`#if target.unicode`, `#if js.classic`): the dot belongs to the flag, not to the
	 * expression, and stopping at it would cut the directive in half and leave the tail to be read
	 * as ordinary code. A dot not followed by an identifier start ends the operand.
	 */
	private static function scanFlagName(source: String, from: Int): Int {
		var i: Int = from;
		while (true) {
			while (i < source.length && Strings.isIdentChar(source.fastCodeAt(i))) i++;
			if (i + 1 >= source.length || source.fastCodeAt(i) != '.'.code) return i;
			if (!Strings.isIdentStart(source.fastCodeAt(i + 1))) return i;
			i += 2;
		}
	}

}
