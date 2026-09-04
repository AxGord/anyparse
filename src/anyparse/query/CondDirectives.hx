package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
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
 * "does a branch open in this gap", and `MemberSlots.extractConditionText` recovers ONE region's
 * condition from its node span. None of them enumerates directives, so the
 * consumers of this class — the `redundant-condcomp-parens` and `cond-region-merge` checks and
 * `apq lit --include-directives` — would otherwise have grown a lexer each. `MemberSlots` shares
 * this class's condition NORMALISATION (`normalizeCondition` / `isBalancedParenWrapped` /
 * `stripOuterParens`) but still reads its own condition text off a node span; the older probes
 * have NOT been migrated onto this reader otherwise; folding them in
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
	 * Every conditional-compilation directive in `source`, in source order. Empty when the
	 * grammar declares no opener keyword, or when the text holds none.
	 */
	public static function scan(source: String, shape: RefShape, regions: () -> Array<LexRegion>): Array<CondDirective> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		if (ifKeyword == null || ifKeyword == '' || source.indexOf(ifKeyword) == -1) return [];
		final keywords: DirectiveKeywords = declaredKeywords(ifKeyword, shape);
		final regions: Array<Span> = SourceComments.collectNonCodeRegions(regions());
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

	/**
	 * The TOP-LEVEL regions `directives` delimits, in source order — one entry per `#if` that no
	 * other region encloses, each carrying what a caller has to know before it may treat the
	 * region as a single lexical unit: whether it opens a branch of its own, whether it holds a
	 * nested region, and whether its two directives own their lines.
	 *
	 * A caller that MOVES a region's text needs all three. `move` carries a `#if`-guarded import
	 * block into another file: an `#else` arm has to travel with the `#if` (so the region is the
	 * unit, not the statement), a nested region cannot be reasoned about branch by branch, and an
	 * inline `#if sys import a; #end` shares its line with code the caller is not moving.
	 *
	 * An UNBALANCED scan stops the walk: the regions read so far are returned and the rest is not
	 * guessed at. A region left open at the end is not returned at all — the direction that costs a
	 * refusal rather than a text slice ending somewhere nobody chose.
	 */
	public static function topLevelBlocks(source: String, directives: Array<CondDirective>, shape: RefShape): Array<CondBlock> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final endKeyword: Null<String> = shape.conditionalEndKeyword;
		if (ifKeyword == null || endKeyword == null) return [];
		final out: Array<CondBlock> = [];
		var depth: Int = 0;
		var openAt: Int = -1;
		var flat: Bool = true;
		var single: Bool = true;
		for (i => directive in directives) {
			if (directive.keyword == ifKeyword) {
				if (depth == 0) {
					openAt = i;
					flat = true;
					single = true;
				} else
					flat = false;
				depth++;
				continue;
			}
			if (directive.keyword == endKeyword) {
				if (depth == 0) return out;
				depth--;
				if (depth == 0 && openAt >= 0) {
					final open: CondDirective = directives[openAt];
					out.push({
						span: new Span(open.span.from, directive.span.to),
						condition: open.condition,
						headerEnd: open.span.to,
						closeFrom: directive.span.from,
						singleBranch: single,
						flat: flat,
						linewise: endsItsLine(source, open.span.to) && SourceText.startsItsLine(source, directive.span.from)
					});
					openAt = -1;
				}
				continue;
			}
			if (depth == 1) single = false;
		}
		return out;
	}

	/**
	 * Whether `span` owns the line it sits on — nothing but blanks on either side of it, with one
	 * optional statement terminator allowed after it (a grammar's own statement span may or may not
	 * reach over its `;`).
	 *
	 * The question a caller asks before MOVING a statement's text: an inline `#if sys import a; #end`
	 * puts a directive on the same line, and taking the statement alone would leave the directive
	 * behind with nothing between it and its `#end`.
	 */
	public static function ownsItsLine(source: String, span: Span): Bool {
		if (!SourceText.startsItsLine(source, span.from)) return false;
		var at: Int = span.to;
		if (at < source.length && source.fastCodeAt(at) == ';'.code) at++;
		return endsItsLine(source, at);
	}


	/** Collapse internal whitespace runs in `condition` to single spaces, so two spellings of one condition compare equal. */
	public static function normalizeCondition(condition: String): String {
		return (~/\s+/g).replace(condition.trim(), ' ');
	}

	/** Whether `condition` is wrapped in ONE outer pair of balanced parentheses spanning the whole string. */
	public static function isBalancedParenWrapped(condition: String): Bool {
		if (!condition.startsWith('(') || !condition.endsWith(')')) return false;
		var depth: Int = 0;
		for (i in 0...condition.length) {
			switch condition.charAt(i) {
				case '(':
					depth++;
				case ')':
					depth--;
					if (depth == 0 && i < condition.length - 1) return false;
				case _:
			}
		}
		return depth == 0;
	}

	/** `condition` with every enclosing pair of balanced parentheses removed - `((sys))` reads as `sys`. */
	public static function stripOuterParens(condition: String): String {
		var text: String = condition;
		while (isBalancedParenWrapped(text)) text = text.substring(1, text.length - 1).trim();
		return text;
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
	 * Whether only blanks stand between `at` and the end of its line — the forward half of
	 * `RefactorSupport.startsItsLine`, which has no twin there.
	 */
	private static function endsItsLine(source: String, at: Int): Bool {
		var i: Int = at;
		while (
			i < source.length
			&& (source.fastCodeAt(i) == ' '.code || source.fastCodeAt(i) == '\t'.code || source.fastCodeAt(i) == '\r'.code)
		)
			i++;
		return i >= source.length || source.fastCodeAt(i) == '\n'.code;
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
	public static function takesCondition(keyword: String, ifKeyword: String, endKeyword: Null<String>): Bool {
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
 * One TOP-LEVEL conditional region, as `CondDirectives.topLevelBlocks` delimits it: `span` runs
 * from the `#if` marker to the end of the `#end` keyword, `headerEnd` is where the opening
 * directive stops and `closeFrom` where the closing one starts — the two offsets that bound the
 * region's BODY — and the three flags say how far the region may be treated as one unit.
 *
 * `singleBranch` is false once the region opens an `#elseif` / `#else` of its own; `flat` is false
 * once it holds a nested region; `linewise` is false for an inline `#if sys f(); #end`, whose
 * directives share their lines with code.
 */
typedef CondBlock = {
	final span: Span;
	final condition: Null<Span>;
	final headerEnd: Int;
	final closeFrom: Int;
	final singleBranch: Bool;
	final flat: Bool;
	final linewise: Bool;
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
