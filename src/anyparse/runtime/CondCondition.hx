package anyparse.runtime;

import anyparse.util.Strings;

/**
 * The one answer to "where does a preprocessor `#if` condition end": `!`* and ONE operand (a
 * parenthesised group, a quoted string, a dotted flag name or a number). The query side's directive
 * reader, the generated parsers' splice predicates and the grammar terminal that captures a condition
 * (`@:scan`) all read a condition here, so one `#if` is one condition for a check and for the parser.
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
		return conditionIn(new StringInput(source), from);
	}

	/** `conditionAt` over a parser's input, read in place rather than copied out. */
	public static function conditionIn(input: Input, from: Int): Null<Span> {
		final start: Int = skipBlank(input, from);
		final end: Int = expressionEnd(input, start);
		return end > start ? new Span(start, end) : null;
	}

	/**
	 * Where the leading `#if` operand of a spliced fragment ends, past the blank after it: the operand
	 * is `conditionAt`'s, so the parser's splice predicates and the query side read one condition. A
	 * fragment carrying no operand (a stray `)`, an unbalanced group) answers the end of the input.
	 */
	public static function skipConditionAtom(source: String, at: Int): Int {
		final input: Input = new StringInput(source);
		final atom: Null<Span> = conditionIn(input, at);
		return atom == null ? source.length : skipBlank(input, atom.to);
	}

	/**
	 * The end of the conditional expression starting exactly at `at`, or `at` when the text holds none:
	 * the `@:scan` reader of a grammar's condition terminal, whose parser has already skipped the blank before it.
	 *
	 * Outside parentheses Haxe reads optional `!` prefixes and ONE operand; a binary operator after
	 * it starts the region's body, not the condition (`#if lime && x` reads `lime`). Stopping there
	 * rather than at the end of the line is the whole point: a region may be written inline
	 * (`#if sys trace(1); #end`), where the tokens after the condition are ordinary code, and
	 * swallowing them would report — and let a fixer rewrite — a span that is not the directive.
	 */
	public static function expressionEnd(input: Input, at: Int): Int {
		var operand: Int = at;
		while (input.charCodeAt(operand) == '!'.code) operand = skipBlank(input, operand + 1);
		final operandEnd: Int = scanOperand(input, operand);
		return operandEnd > operand ? operandEnd : at;
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

	/** The end of the single operand at `at` — a parenthesised group, a quoted string, an identifier or a number — or `at` when none. */
	private static function scanOperand(input: Input, at: Int): Int {
		final c: Int = input.charCodeAt(at);
		if (c == '('.code) return scanParens(input, at);
		if (isQuote(c)) return Strings.quotedEndOf(input.charCodeAt, at);
		if (Strings.isIdentStart(c)) return scanFlagName(input, at + 1);
		if (!isDigit(c)) return at;
		var i: Int = at + 1;
		while (true) {
			final digit: Int = input.charCodeAt(i);
			if (!isDigit(digit) && digit != '.'.code) break;
			i++;
		}
		return i;
	}

	/**
	 * The index just past the `)` matching the `(` at `at`, or `at` when the group is unbalanced; a group may span lines.
	 * A block comment inside the group is comment text — a quote or a paren in it opens nothing — and an unclosed one
	 * leaves the group unbalanced. A line comment is not skipped: Haxe refuses one inside a condition group.
	 */
	private static function scanParens(input: Input, at: Int): Int {
		var depth: Int = 0;
		var i: Int = at;
		while (i < input.length) {
			final c: Int = input.charCodeAt(i);
			if (c == '/'.code && input.charCodeAt(i + 1) == '*'.code) {
				final closed: Int = blockCommentEnd(input, i + 2);
				if (closed < 0) return at;
				i = closed;
				continue;
			}
			if (isQuote(c)) {
				final quoted: Int = Strings.quotedEndOf(input.charCodeAt, i);
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

	/** The index just past the star-slash closing a block comment whose body starts at `from`, or -1 when it never closes. */
	private static function blockCommentEnd(input: Input, from: Int): Int {
		var i: Int = from;
		while (i + 1 < input.length) {
			if (input.charCodeAt(i) == '*'.code && input.charCodeAt(i + 1) == '/'.code) return i + 2;
			i++;
		}
		return -1;
	}

	/** The index of the first character at or after `at` that is not whitespace, line breaks included. */
	private static function skipBlank(input: Input, at: Int): Int {
		var i: Int = at;
		while (i < input.length) {
			final c: Int = input.charCodeAt(i);
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
	private static function scanFlagName(input: Input, from: Int): Int {
		var i: Int = from;
		while (true) {
			while (Strings.isIdentChar(input.charCodeAt(i))) i++;
			if (input.charCodeAt(i) != '.'.code || !Strings.isIdentStart(input.charCodeAt(i + 1))) return i;
			i += 2;
		}
	}

}
