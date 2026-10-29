package anyparse.check.common.docs;

/**
 * Where the numbers, words and counts of comment prose start and end — the token arithmetic
 * `doc-measurement-claim` reads its shapes with. Every function takes the comment's end as `to` and
 * never reads past it: what follows a comment is code.
 */
@:nullSafety(Strict)
final class ProseNumbers {

	/**
	 * The fewest leading digits a census count is read with. Below it a number is the size of a
	 * fixture or a contract's own small quantity, which prose states and a census does not.
	 */
	private static inline final CENSUS_FLOOR_DIGITS: Int = 2;

	/** The fewest digits a number after an acronym is read as the standard's own number with. */
	private static inline final STANDARD_DIGITS: Int = 3;

	/** The digits a year is written with. */
	private static inline final YEAR_DIGITS: Int = 4;

	/** The digits one typeset thousands group carries. */
	private static inline final GROUP_DIGITS: Int = 3;

	/** The code units besides a space a count may follow: brackets, quotes, a tilde, an em dash. */
	private static final COUNT_OPENERS: Array<Int> = ['('.code, '['.code, '~'.code, '"'.code, '\''.code, 0x2014];

	/** The words before a count that make it a bound the code declares. */
	private static final BOUND_WORDS: Array<String> = [
		'after',
		'top',
		'into',
		'per',
		'limit',
		'max',
		'maximum',
		'min',
		'minimum',
		'within',
		'every'
	];

	/** The two-word phrases before a count that make it a bound. */
	private static final BOUND_PAIRS: Array<String> = ['at most', 'at least', 'up to'];

	/** What follows a counted noun to make the count a rate or a bound. */
	private static final BOUND_TAILS: Array<String> = [' per ', ' at a time', ' at once', ' each'];

	/** The spaces a typeset number groups its thousands with: thin, narrow no-break, no-break. */
	private static final GROUP_SPACES: Array<Int> = [0x2009, 0x202F, 0x00A0];

	/**
	 * The plural nouns a census counts — what a run over one tree finds, edits or reads. A dimension a
	 * contract bounds (lines, members, columns, statements) is deliberately absent.
	 */
	private static final CENSUS_NOUNS: Array<String> = [
		'files',
		'findings',
		'sites',
		'edits',
		'rules',
		'checks',
		'blocks',
		'tests',
		'fixtures',
		'hits',
		'readings',
		'occurrences',
		'violations',
		'arms',
		'pins',
		'claims',
		'commits',
		'slices',
		'sources',
		'assertions',
		'survivors',
		'mutants',
		'cells',
		'candidates',
		'callers',
		'fires',
		'modules'
	];

	/** The numbers from eleven up spelled as one word; a smaller one is ordinary prose about a contract. */
	private static final TEENS: Array<String> = [
		'eleven',
		'twelve',
		'thirteen',
		'fourteen',
		'fifteen',
		'sixteen',
		'seventeen',
		'eighteen',
		'nineteen'
	];

	/** The tens a spelled number opens with. */
	private static final TENS: Array<String> = ['twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];

	/** What may follow a spelled ten after its hyphen: a unit, or the word that rounds it. */
	private static final TEN_TAILS: Array<String> = ['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'odd'];

	/** Whether `code` is an ASCII decimal digit. */
	public static inline function isDigit(code: Int): Bool {
		return code >= '0'.code && code <= '9'.code;
	}

	/** Whether `code` separates a number from its decimal group, in either convention. */
	public static inline function isDecimalSeparator(code: Int): Bool {
		return code == '.'.code || code == ','.code;
	}

	/** Where the identifier token at `at` ends; `at` itself when none starts there. */
	public static function tokenEnd(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && SourceText.isIdentChar(source.fastCodeAt(i))) i++;
		return i;
	}

	/** Where the number at `at` ends, one decimal group included; `at` itself when none starts there. */
	public static function numberEnd(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && isDigit(source.fastCodeAt(i))) i++;
		if (i == at) return at;
		if (i + 1 < to && isDecimalSeparator(source.fastCodeAt(i)) && isDigit(source.fastCodeAt(i + 1))) {
			i++;
			while (i < to && isDigit(source.fastCodeAt(i))) i++;
		}
		return i;
	}

	/** How many digits open the number at `at`, before any separator. */
	public static function leadingDigits(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && isDigit(source.fastCodeAt(i))) i++;
		return i - at;
	}

	/** Where the thousands groups typeset after the number ending at `from` close; `from` itself when none follow. */
	public static function groupedEnd(source: String, to: Int, from: Int): Int {
		var end: Int = from;
		while (end < to && GROUP_SPACES.contains(source.fastCodeAt(end)) && leadingDigits(source, to, end + 1) == GROUP_DIGITS)
			end += 1 + GROUP_DIGITS;
		return end;
	}

	/** Where a number from eleven up spelled as one word ends (`Fifty-eight`, `eleven`), or `at` when none starts there. */
	public static function spelledNumberEnd(source: String, to: Int, at: Int): Int {
		final end: Int = tokenEnd(source, to, at);
		if (TEENS.exists(word -> tokenEqualsIgnoringCase(source, at, end, word))) return end;
		if (!TENS.exists(word -> tokenEqualsIgnoringCase(source, at, end, word))) return at;
		if (end + 1 >= to || source.fastCodeAt(end) != '-'.code) return end;
		final tail: Int = tokenEnd(source, to, end + 1);
		return TEN_TAILS.exists(word -> tokenEqualsIgnoringCase(source, end + 1, tail, word)) ? tail : end;
	}

	/**
	 * Where the census noun after the count ending at `from` ends, or -1 — the noun itself, or the noun
	 * behind ONE modifier, an adjective or a compound. The noun is matched in lower case: a capitalised
	 * one is a heading or a tool's own output quoted in prose.
	 */
	public static function censusNounEnd(source: String, to: Int, from: Int): Int {
		if (from >= to || source.fastCodeAt(from) != ' '.code) return -1;
		final first: Int = from + 1;
		final firstEnd: Int = wordEnd(source, to, first);
		if (firstEnd == first) return -1;
		if (isCensusNoun(source, first, firstEnd)) return firstEnd;

		if (firstEnd >= to || source.fastCodeAt(firstEnd) != ' '.code) return -1;
		final second: Int = firstEnd + 1;
		final secondEnd: Int = wordEnd(source, to, second);
		return secondEnd > second && isCensusNoun(source, second, secondEnd) ? secondEnd : -1;
	}

	/** Whether the token `[at, end)` reads as `word`, case ignored. */
	public static function tokenEqualsIgnoringCase(source: String, at: Int, end: Int, word: String): Bool {
		return end - at == word.length && matchesIgnoringCase(source, end, at, word);
	}

	/** Whether `word` stands at `at`, case ignored and never reading past `to`. */
	public static function matchesIgnoringCase(source: String, to: Int, at: Int, word: String): Bool {
		if (at + word.length > to) return false;
		for (i in 0...word.length) if (lowered(source.fastCodeAt(at + i)) != lowered(word.fastCodeAt(i))) return false;
		return true;
	}

	/**
	 * Whether the number at `at` is large enough to be read as a census: two leading digits, or one
	 * group of thousands after a comma.
	 */
	public static function isCensusSized(source: String, to: Int, at: Int): Bool {
		final leading: Int = leadingDigits(source, to, at);
		if (leading >= CENSUS_FLOOR_DIGITS) return true;
		final comma: Int = at + leading;
		return comma < to && source.fastCodeAt(comma) == ','.code && leadingDigits(source, to, comma + 1) == GROUP_DIGITS;
	}

	/**
	 * Whether the count `[at, end)` (its noun included) states a CONTRACT rather than a census: it is
	 * glued to the token before it (a fraction's digits, `#12`, `C++20`, a hyphenated name), it is a
	 * bound (`after`, `at most`, `up to`, `top`, `into`, `per`, … before it, or `per` / `at a time`
	 * after it), or it is a standard's or a year's number (`RFC 4180`, `2024`). A bound is what code
	 * declares; a census is what a run found.
	 */
	public static function readsAsContract(source: String, from: Int, to: Int, at: Int, end: Int): Bool {
		if (at > from && !opensCount(source.fastCodeAt(at - 1))) return true;
		final last: Int = wordStartBefore(source, from, at);
		final lastWord: String = source.substring(last, trimmedEnd(source, last, at)).toLowerCase();
		if (BOUND_WORDS.contains(lastWord)) return true;
		final previous: Int = wordStartBefore(source, from, last);
		if (BOUND_PAIRS.contains('${source.substring(previous, trimmedEnd(source, previous, last)).toLowerCase()} $lastWord')) return true;
		final digits: Int = leadingDigits(source, to, at);
		return digits >= STANDARD_DIGITS && isAcronym(source, last, trimmedEnd(source, last, at)) || digits == YEAR_DIGITS
			&& isYear(source.substr(at, YEAR_DIGITS)) || BOUND_TAILS.exists(tail -> matchesIgnoringCase(source, to, end, tail));
	}

	/** `code` as its lower-case self, for the ASCII letters every marker is written in. */
	private static inline function lowered(code: Int): Int {
		return code >= 'A'.code && code <= 'Z'.code ? code + ('a'.code - 'A'.code) : code;
	}

	/** Where the prose word at `at` ends — letters, digits, and the hyphen or apostrophe inside a word. */
	private static function wordEnd(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && (i == at ? SourceText.isIdentChar(source.fastCodeAt(i)) : continuesWord(source, to, i))) i++;
		return i;
	}

	/** Whether a hyphen or apostrophe at `at` joins two halves of one word. */
	private static function continuesWord(source: String, to: Int, at: Int): Bool {
		if (at >= to) return false;
		final c: Int = source.fastCodeAt(at);
		return SourceText.isIdentChar(c) || (c == '-'.code || c == '\''.code) && at + 1 < to
			&& SourceText.isIdentChar(source.fastCodeAt(at + 1));
	}

	/** Whether the word `[at, end)` is a noun a census counts. */
	private static function isCensusNoun(source: String, at: Int, end: Int): Bool {
		return CENSUS_NOUNS.contains(source.substring(at, end));
	}

	/** Whether a count may start right after `code`: a space, an opening bracket or quote, a tilde, a dash that breaks prose. */
	private static function opensCount(code: Int): Bool {
		return SourceText.isSpace(code) || COUNT_OPENERS.contains(code);
	}

	/** Where the word ending (before spaces) at `at` starts; `at` itself when none does. */
	private static function wordStartBefore(source: String, from: Int, at: Int): Int {
		var i: Int = at;
		while (i > from && source.fastCodeAt(i - 1) == ' '.code) i--;
		while (i > from && SourceText.isIdentChar(source.fastCodeAt(i - 1))) i--;
		return i;
	}

	/** Where the word starting at `start` ends, never past `limit`. */
	private static function trimmedEnd(source: String, start: Int, limit: Int): Int {
		var i: Int = start;
		while (i < limit && SourceText.isIdentChar(source.fastCodeAt(i))) i++;
		return i;
	}

	/** Whether `[at, end)` is an upper-case acronym of two letters or more — a standard's or a body's name. */
	private static function isAcronym(source: String, at: Int, end: Int): Bool {
		if (end - at < 2) return false;
		for (i in at ... end) {
			final c: Int = source.fastCodeAt(i);
			if (c < 'A'.code || c > 'Z'.code) return false;
		}
		return true;
	}

	/** Whether four digits read as a year of the last century or this one. */
	private static function isYear(digits: String): Bool {
		return digits.startsWith('19') || digits.startsWith('20');
	}

}
