package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The shared conditional-compilation directive reader: the one place its consumers locate a
 * grammar's `#if` / `#elseif` / `#else` / `#end` occurrences in a source text and delimit each one's
 * condition.
 *
 * A directive is not a node. A `Conditional` region projects its BRANCH STATEMENTS as children and
 * the directive text itself survives only as trivia on the line, so every consumer that needs the
 * text has to read the source — and until this class there was no shared read, only per-caller
 * probes: `CondBranchProjection.gapHasBranchDirective` and `MemberOrder.hasBranchDirective` answer
 * "does a branch open in this gap", and `MemberOrder.extractConditionText` recovers ONE region's
 * condition from its node span. None of them enumerates directives, so both consumers of this class
 * — the `redundant-condcomp-parens` check and `apq lit --include-directives` — would otherwise have
 * grown a lexer each. Those older probes have NOT been migrated onto this reader; folding them in
 * (and with them the hardcoded `#end` / `#else` spellings in `MemberOrder`, `CondAssignMerge`,
 * `IfFalseDeadCode` and `TailMerge`) is the follow-up that would make the first sentence true of the
 * whole engine rather than of this class's own consumers.
 *
 * The scan is lexical and shares the engine's single lexer through
 * `RefactorSupport.collectNonCodeRegions`, so a `#if` written inside a comment, a string literal or
 * a regex literal is not a directive. That masking bounds where a directive may START; the condition
 * scan itself reads raw text, so a block comment written INSIDE a condition is not masked and its
 * closing delimiter is read as ordinary condition text. An unterminated string swallows the rest of
 * the file as non-code, which costs a directive after it — acceptable, since the alternative is
 * guessing where the literal was meant to end.
 *
 * Needing no parse is what lets a consumer run on a file the grammar cannot parse.
 *
 * Grammar-agnostic: the keyword vocabulary comes from `RefShape.conditionalIfKeyword`,
 * `conditionalElseKeywords` and `conditionalEndKeyword`; a grammar declaring no opener scans to
 * nothing. Every declared keyword contributes its own first character to the marker set, so no
 * keyword is missed for sharing or not sharing the opener's sigil.
 */
@:nullSafety(Strict)
final class CondDirectives {

	/** The condition operators recognised between two operands, longest first so `>` never shadows `>=`. */
	private static final OPERATORS: Array<String> = ['&&', '||', '==', '!=', '>=', '<=', '>', '<'];

	private function new() {}

	/**
	 * Every conditional-compilation directive in `source`, in source order. Empty when the
	 * grammar declares no opener keyword, or when the text holds none.
	 */
	public static function scan(source: String, shape: RefShape): Array<CondDirective> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		if (ifKeyword == null || ifKeyword == '' || source.indexOf(ifKeyword) == -1) return [];
		final keywords: DirectiveKeywords = declaredKeywords(ifKeyword, shape);
		final regions: Array<Span> = RefactorSupport.collectNonCodeRegions(source);
		final out: Array<CondDirective> = [];
		var region: Int = 0;
		var i: Int = 0;
		while (i < source.length) {
			while (region < regions.length && regions[region].to <= i) region++;
			if (region < regions.length && i >= regions[region].from) {
				i = regions[region].to;
				continue;
			}
			final keyword: Null<String> = keywords.markers.contains(source.fastCodeAt(i)) ? keywordAt(source, i, keywords.all) : null;
			if (keyword == null) {
				i++;
				continue;
			}
			final directive: CondDirective = read(source, i, keyword, keywords);
			out.push(directive);
			i = directive.span.to;
		}
		return out;
	}

	/** The verbatim directive text of `directive` — its keyword plus its condition, e.g. `#if (sys)` / `#elseif js` / `#end`. */
	public static inline function text(source: String, directive: CondDirective): String {
		return source.substring(directive.span.from, directive.span.to);
	}

	/** Whether `c` can open an identifier. */
	public static inline function isIdentStart(c: Int): Bool {
		return c == '_'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code;
	}

	/** Whether `c` can continue an identifier. */
	public static inline function isIdentChar(c: Int): Bool {
		return isIdentStart(c) || isDigit(c);
	}

	/**
	 * Whether `source` holds an identifier character at `at` — the positional form of
	 * `isIdentChar`, for a caller asking whether a neighbour would lex into one token with an
	 * identifier spliced next to it. Out of range answers false: nothing there to weld with.
	 */
	public static inline function isIdentCharAt(source: String, at: Int): Bool {
		return at >= 0 && at < source.length && isIdentChar(source.fastCodeAt(at));
	}

	/**
	 * The grammar's directive keywords, longest first so `#elseif` is never read as `#else` followed by
	 * an `if` flag, together with the set of characters that can open one. Duplicates and empty
	 * spellings are dropped — a grammar is free to repeat the opener in its branch list.
	 */
	private static function declaredKeywords(ifKeyword: String, shape: RefShape): DirectiveKeywords {
		final all: Array<String> = [ifKeyword];
		for (keyword in shape.conditionalElseKeywords ?? []) if (keyword != '' && !all.contains(keyword)) all.push(keyword);
		final closer: Null<String> = shape.conditionalEndKeyword;
		if (closer != null && closer != '' && !all.contains(closer)) all.push(closer);
		all.sort((a, b) -> b.length - a.length);
		return {
			all: all,
			markers: [for (keyword in all) keyword.fastCodeAt(0)],
			opener: ifKeyword,
			closer: closer
		};
	}

	/**
	 * The declared keyword `source` carries at `at`, or null. The match is token-terminated: a
	 * keyword directly followed by an identifier character is a longer word, not this directive
	 * (`#ifdef` is not `#if`).
	 */
	private static function keywordAt(source: String, at: Int, keywords: Array<String>): Null<String> {
		for (keyword in keywords) {
			final end: Int = at + keyword.length;
			if (end > source.length || source.substring(at, end) != keyword) continue;
			if (end == source.length || !isIdentChar(source.fastCodeAt(end))) return keyword;
		}
		return null;
	}

	/**
	 * The directive starting at `from` with the already-matched `keyword`, condition included when it
	 * takes one.
	 */
	private static function read(source: String, from: Int, keyword: String, keywords: DirectiveKeywords): CondDirective {
		final afterKeyword: Int = from + keyword.length;
		final condition: Null<Span> = takesCondition(keyword, keywords.opener, keywords.closer) ? conditionAt(source, afterKeyword) : null;
		return {
			keyword: keyword,
			span: new Span(from, condition == null ? afterKeyword : condition.to),
			condition: condition
		};
	}

	/**
	 * Whether `keyword` carries a condition. The declared CLOSER never does — checked first, because
	 * a closer spelled `#endif` would otherwise satisfy the branch test below. The opener always does;
	 * a branch keyword does exactly when it ENDS with the opener's bare word — `#elseif` does, `#else`
	 * does not. That is the shape of the branch keyword in every C-preprocessor-descended grammar, and
	 * the only discrimination the declared seams support without a third keyword list. A grammar whose
	 * branch keyword is spelled otherwise loses its condition span, never its directive.
	 */
	private static function takesCondition(keyword: String, ifKeyword: String, endKeyword: Null<String>): Bool {
		return keyword != endKeyword && (keyword == ifKeyword || keyword.endsWith(ifKeyword.substring(1)));
	}

	/**
	 * The condition span starting after a keyword at `from`, or null when the directive carries
	 * none. Never crosses a newline: a condition is a single-line directive tail.
	 */
	private static function conditionAt(source: String, from: Int): Null<Span> {
		final start: Int = skipInlineSpace(source, from);
		final end: Int = scanExpression(source, start);
		return end > start ? new Span(start, end) : null;
	}

	/**
	 * The end of the conditional expression at `at`, or `at` when the text holds none.
	 *
	 * The scan is a operand / operator alternation — optional `!` prefixes, then an operand,
	 * then an operator that demands another operand — and it stops at the first token that
	 * continues neither. Stopping there rather than at the end of the line is the whole point:
	 * a region may be written inline (`#if sys trace(1); #end`), where the tokens after the
	 * condition are ordinary code, and swallowing them would report — and let a fixer rewrite —
	 * a span that is not the directive.
	 */
	private static function scanExpression(source: String, at: Int): Int {
		var i: Int = at;
		var end: Int = at;
		while (true) {
			var operand: Int = i;
			while (operand < source.length && source.fastCodeAt(operand) == '!'.code) operand = skipInlineSpace(source, operand + 1);
			final operandEnd: Int = scanOperand(source, operand);
			if (operandEnd <= operand) return end;
			end = operandEnd;
			final afterOperand: Int = skipInlineSpace(source, operandEnd);
			final binaryOp: Null<String> = operatorAt(source, afterOperand);
			if (binaryOp == null) return end;
			i = skipInlineSpace(source, afterOperand + binaryOp.length);
		}
	}

	/** The end of the single operand at `at` — a parenthesised group, a quoted string, an identifier or a number — or `at` when none. */
	private static function scanOperand(source: String, at: Int): Int {
		if (at >= source.length) return at;
		final c: Int = source.fastCodeAt(at);
		if (c == '('.code) return scanParens(source, at);
		if (isQuote(c)) return scanQuoted(source, at);
		if (isIdentStart(c)) return scanFlagName(source, at + 1);
		if (!isDigit(c)) return at;
		var i: Int = at + 1;
		while (i < source.length) {
			final digit: Int = source.fastCodeAt(i);
			if (!isDigit(digit) && digit != '.'.code) break;
			i++;
		}
		return i;
	}

	/** The index just past the `)` matching the `(` at `at`, or `at` when the group is unbalanced or runs past the line. */
	private static function scanParens(source: String, at: Int): Int {
		var depth: Int = 0;
		var i: Int = at;
		while (i < source.length) {
			final c: Int = source.fastCodeAt(i);
			if (isLineBreak(c)) return at;
			if (isQuote(c)) {
				final quoted: Int = scanQuoted(source, i);
				if (quoted <= i) return at;
				i = quoted;
				continue;
			}
			if (c == '('.code)
				depth++;
			else if (c == ')'.code) {
				depth--;
				if (depth == 0) return i + 1;
			}
			i++;
		}
		return at;
	}

	/** The index just past the string literal opening at `at`, or `at` when it is unterminated on its line. */
	private static function scanQuoted(source: String, at: Int): Int {
		final quote: Int = source.fastCodeAt(at);
		var i: Int = at + 1;
		while (i < source.length) {
			final c: Int = source.fastCodeAt(i);
			if (isLineBreak(c)) return at;
			if (c == '\\'.code) {
				// The escape must not step OVER a line break: the condition is a single-line tail,
				// and a trailing backslash in text the grammar never accepted would otherwise carry
				// the scan into the next line.
				if (i + 1 >= source.length || isLineBreak(source.fastCodeAt(i + 1))) return at;
				i += 2;
				continue;
			}
			if (c == quote) return i + 1;
			i++;
		}
		return at;
	}

	/** The condition operator `source` carries at `at`, or null. */
	private static function operatorAt(source: String, at: Int): Null<String> {
		return OPERATORS.find(candidate -> source.substring(at, at + candidate.length) == candidate);
	}

	/** The index of the first character at or after `at` that is neither a space nor a tab; a line break stops the skip. */
	private static function skipInlineSpace(source: String, at: Int): Int {
		var i: Int = at;
		while (i < source.length) {
			final c: Int = source.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code) return i;
			i++;
		}
		return i;
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
	 * The end of the identifier operand whose first character sits at `from - 1`. A define name may
	 * be DOTTED (`#if target.unicode`, `#if js.classic`): the dot belongs to the flag, not to the
	 * expression, and stopping at it would cut the directive in half and leave the tail to be read
	 * as ordinary code. A dot not followed by an identifier start ends the operand.
	 */
	private static function scanFlagName(source: String, from: Int): Int {
		var i: Int = from;
		while (true) {
			while (i < source.length && isIdentChar(source.fastCodeAt(i))) i++;
			if (i + 1 >= source.length || source.fastCodeAt(i) != '.'.code) return i;
			if (!isIdentStart(source.fastCodeAt(i + 1))) return i;
			i += 2;
		}
	}

}

/**
 * One conditional-compilation directive recovered by `CondDirectives.scan`: the `keyword` as the
 * grammar declares it, the `span` of the whole directive — from its marker character to the end
 * of its condition, or to the end of the keyword when it carries none — and `condition`, the span
 * of the condition text alone (null for a keyword that takes none, and for a condition-bearing
 * keyword whose tail the reader could not delimit).
 *
 * The span deliberately stops at the condition rather than at the end of the physical line: an
 * inline region (`#if sys trace(1); #end`) continues with ordinary code on the same line, and
 * neither a text search nor a fixer may be handed that as directive text.
 */
typedef CondDirective = {
	final keyword: String;
	final span: Span;
	final condition: Null<Span>;
};

/**
 * The directive keyword vocabulary `CondDirectives.scan` threads through one walk: every declared
 * keyword longest-first (so a longer keyword is never read as a shorter prefix of itself), the set
 * of first characters that can open one, and the opener / closer singled out because a keyword's
 * condition-bearing-ness is decided against them.
 */
private typedef DirectiveKeywords = {
	final all: Array<String>;
	final markers: Array<Int>;
	final opener: String;
	final closer: Null<String>;
};
