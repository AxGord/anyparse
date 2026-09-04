package anyparse.macro;

using StringTools;

/**
 * The exhaustive set of byte codes a match of a `@:re` terminal's pattern can
 * BEGIN with — the fact `ParseDispatchLowering.terminalFirstToken` turns into a
 * `BranchFirstToken.FirstLit`, and through that into both the Alt dispatch
 * guards and the terminal's own first-byte reject.
 *
 * `null` means "not established with certainty", and it is the safe answer: it
 * costs nothing but the guard we did not get. Every non-null answer must be a
 * SUPERSET of the true first-byte set. An answer that MISSES a byte makes a
 * dispatch guard skip a branch whose trial would have matched, and that is the
 * one defect no runtime oracle catches — so every construct whose head this
 * cannot pin down answers `null` on purpose: `.`, a negated class, `\s`, a
 * backreference, a `{n,m}` quantifier, a named group.
 *
 * The anchoring the answer is read against is `Codegen.eregField`'s: the EReg
 * is built as `^${pattern}`, and `|` binds looser than concatenation, so
 * `^A|B` parses as `(^A)|B` and anchors only the first alternative. What makes
 * a UNION over ALL top-level alternatives sound anyway is
 * `Lowering.lowerTerminal`'s `matchedPos().pos != 0` reject: the terminal
 * accepts exactly the matches that begin AT the cursor, whichever alternative
 * produced them, so a first byte outside the union cannot start any accepted
 * match. That reject is why this answers a union where the previous
 * `headIsMandatory` scan refused a top-level `|` outright.
 *
 * The answer is a claim about a BYTE, and `MAX_BYTE` is what keeps it one. The
 * pattern is a Haxe `String`, so this reads CODE UNITS, while the guard it feeds
 * compares `Input.charCodeAt`. Those agree for `StringInput` and part company
 * for `BytesInput`, whose `charCodeAt` answers a raw UTF-8 byte while its
 * `substring` — the text the `EReg` actually runs on — DECODES: a head of
 * U+00E9 would be claimed as 233 and seen by the guard as 195, the too-narrow
 * direction. No binary grammar declares a `@:re` today; refusing the whole
 * non-ASCII range costs nothing now and closes the gap before one does.
 *
 * Not a regex engine, and never a validator: a pattern it cannot follow is one
 * it makes no claim about.
 *
 * Deliberately NOT `#if macro`, unlike every sibling in this package: the
 * soundness of every claim above rests on `RegexFirstBytesTest`, and a test
 * runs on the js target. Nothing here touches `haxe.macro`.
 */
@:nullSafety(Strict)
final class RegexFirstBytes {

	/**
	 * Highest code an answer may contain — see the class doc. Above it the
	 * claim would be a CODE POINT while a `BytesInput`-backed guard compares a
	 * UTF-8 lead byte, which is the too-narrow direction.
	 *
	 * It is also the ONLY size bound this needs. Capping the code value at
	 * 0x7F caps any answer at 128 distinct codes, which `ParseDispatchLowering.byteRuns`
	 * collapses to at most 64 guard terms — cheaper than the one thrown
	 * backtrack the guard replaces, even at that absurd worst case. The
	 * widest the shipped grammars actually ask for is `HxPpCondLit`'s 65
	 * codes in 6 runs.
	 */
	private static inline final MAX_BYTE: Int = 0x7F;

	/** `\f` — the one control escape with no Haxe string spelling. */
	private static inline final FORM_FEED: Int = 12;

	/** `\v` — the one control escape with no Haxe string spelling. */
	private static inline final VERTICAL_TAB: Int = 11;

	/**
	 * First-byte set of `pattern` — the regex source `Codegen.eregField`
	 * anchors, without the leading `^` and without slashes or flags.
	 */
	public static function of(pattern: Null<String>): Null<Array<Int>> {
		if (pattern == null || pattern.length == 0) return null;
		final codes: Null<Array<Int>> = alternation(pattern, 0, pattern.length);
		if (codes == null || codes.length == 0) return null;
		codes.sort((a, b) -> a - b);
		return codes;
	}

	/**
	 * Union over the alternatives `pattern[from...to)` separated by `|` at
	 * paren depth 0 outside a character class. One unclassifiable alternative
	 * poisons the whole union: it can begin with anything.
	 */
	private static function alternation(pattern: String, from: Int, to: Int): Null<Array<Int>> {
		final codes: Array<Int> = [];
		var start: Int = from;
		var depth: Int = 0;
		var inClass: Bool = false;
		var i: Int = from;
		while (i < to) {
			final c: Int = pattern.fastCodeAt(i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (inClass) {
				if (c == ']'.code) inClass = false;
				i++;
				continue;
			}
			switch c {
				case '['.code:
					inClass = true;
				case '('.code:
					depth++;
				case ')'.code:
					depth--;
				case '|'.code:
					if (depth == 0) {
						if (!absorb(codes, sequence(pattern, start, i))) return null;
						start = i + 1;
					}
			}
			if (depth < 0) return null;
			i++;
		}
		if (depth != 0 || inClass) return null;
		final tail: Null<Array<Int>> = sequence(pattern, start, to);
		return absorb(codes, tail) ? codes : null;
	}

	/**
	 * First-byte set of one alternative — the head of its first element that
	 * can actually consume a byte.
	 *
	 * Zero-width elements (`^`, `$`, `\b`, `\B`, a lookahead or lookbehind
	 * group) are stepped over: a match must satisfy them AND then consume what
	 * follows, so the set of what FOLLOWS is a superset of the true one.
	 *
	 * An element a `?` or `*` quantifier can erase hands the question on to
	 * the rest of the alternative and unions the two answers, which is what
	 * classifies the `\$?[A-Za-z_]…` and `-?(?:0|[1-9][0-9]*)` heads. An
	 * alternative that runs out of elements answers `null` — it matches the
	 * empty string, so its first byte is whatever follows the terminal.
	 */
	private static function sequence(pattern: String, from: Int, to: Int): Null<Array<Int>> {
		var i: Int = from;
		while (i < to) {
			final assertionEnd: Int = zeroWidthEnd(pattern, i, to);
			if (assertionEnd > i) {
				i = assertionEnd;
				continue;
			}
			final end: Null<Int> = elementEnd(pattern, i, to);
			if (end == null) return null;
			final next: Int = quantifierEnd(pattern, end, to);
			if (next < 0) return null;
			if (isLookaround(pattern, i, to)) {
				// A quantified lookaround is legal ECMAScript and says
				// nothing this reader can use; refuse rather than guess.
				if (next != end) return null;
				i = next;
				continue;
			}
			final own: Null<Array<Int>> = elementBytes(pattern, i, end);
			if (own == null) return null;
			if (!erasable(pattern, end, to)) return own;
			final rest: Null<Array<Int>> = sequence(pattern, next, to);
			return absorb(own, rest) ? own : null;
		}
		return null;
	}

	/**
	 * Index past a zero-width assertion at `at` — an anchor or a word
	 * boundary — or `at` itself when there is none. A lookaround group is
	 * zero-width too, but it needs `elementEnd` to delimit it, so
	 * `sequence` steps over that one separately.
	 */
	private static function zeroWidthEnd(pattern: String, at: Int, to: Int): Int {
		final c: Int = pattern.fastCodeAt(at);
		if (c == '^'.code || c == '$'.code) return at + 1;
		if (c != '\\'.code || at + 1 >= to) return at;
		final esc: Int = pattern.fastCodeAt(at + 1);
		return esc == 'b'.code || esc == 'B'.code ? at + 2 : at;
	}

	/**
	 * Index past the quantifier that follows the element ending at `end`,
	 * its lazy `?` included; `end` itself when the element carries none.
	 * `-1` for a `{n,m}` counted quantifier — reading its minimum is the
	 * one case where a wrong answer would erase a mandatory head.
	 */
	private static function quantifierEnd(pattern: String, end: Int, to: Int): Int {
		if (end >= to) return end;
		final quant: Int = pattern.fastCodeAt(end);
		if (quant == '{'.code) return -1;
		if (quant != '?'.code && quant != '*'.code && quant != '+'.code) return end;
		final lazy: Int = end + 1;
		return lazy < to && pattern.fastCodeAt(lazy) == '?'.code ? lazy + 1 : lazy;
	}

	/** Whether the quantifier after `end` lets the element match nothing. */
	private static function erasable(pattern: String, end: Int, to: Int): Bool {
		if (end >= to) return false;
		final quant: Int = pattern.fastCodeAt(end);
		return quant == '?'.code || quant == '*'.code;
	}

	/**
	 * Index just past the element starting at `at`, quantifier NOT included.
	 * `null` for anything the scan cannot delimit — an unterminated class or
	 * group, a dangling escape, or a quantifier / alternation character where
	 * an element was expected.
	 */
	private static function elementEnd(pattern: String, at: Int, to: Int): Null<Int> {
		final c: Int = pattern.fastCodeAt(at);
		if (c == '\\'.code) return at + 2 <= to ? at + 2 : null;
		if (c == '['.code) {
			var i: Int = at + 1;
			if (i < to && pattern.fastCodeAt(i) == '^'.code) i++;
			while (i < to) {
				final m: Int = pattern.fastCodeAt(i);
				if (m == '\\'.code) {
					i += 2;
					continue;
				}
				if (m == ']'.code) return i + 1;
				i++;
			}
			return null;
		}
		if (c != '('.code) return switch c {
			case ')'.code, '|'.code, '*'.code, '+'.code, '?'.code, '{'.code, '}'.code, ']'.code: null;
			case _: at + 1;
		};
		var depth: Int = 0;
		var inClass: Bool = false;
		var i: Int = at;
		while (i < to) {
			final m: Int = pattern.fastCodeAt(i);
			if (m == '\\'.code) {
				i += 2;
				continue;
			}
			if (inClass) {
				if (m == ']'.code) inClass = false;
				i++;
				continue;
			}
			switch m {
				case '['.code:
					inClass = true;
				case '('.code:
					depth++;
				case ')'.code:
					depth--;
					if (depth == 0) return i + 1;
			}
			i++;
		}
		return null;
	}

	/** Whether the group at `at` is a lookahead or lookbehind — zero-width, so it consumes no byte. */
	private static function isLookaround(pattern: String, at: Int, to: Int): Bool {
		if (pattern.fastCodeAt(at) != '('.code) return false;
		var i: Int = at + 1;
		if (i >= to || pattern.fastCodeAt(i) != '?'.code) return false;
		i++;
		if (i < to && pattern.fastCodeAt(i) == '<'.code) i++;
		if (i >= to) return false;
		final c: Int = pattern.fastCodeAt(i);
		return c == '='.code || c == '!'.code;
	}

	/** First-byte set of the single element `pattern[at...end)`, quantifier excluded. */
	private static function elementBytes(pattern: String, at: Int, end: Int): Null<Array<Int>> {
		final c: Int = pattern.fastCodeAt(at);
		if (c == '\\'.code) return escapeBytes(pattern.fastCodeAt(at + 1));
		if (c == '['.code) return classBytes(pattern, at + 1, end - 1);
		if (c != '('.code) return c == '.'.code ? null : [c];
		var start: Int = at + 1;
		if (pattern.fastCodeAt(start) == '?'.code) {
			// `(?:` is the only group prefix with a head to read. `(?=` /
			// `(?!` / `(?<=` / `(?<!` never reach here (`isLookaround`
			// takes them), and a named `(?<name>` group is left
			// unclassified rather than parsed for its `>`.
			if (start + 1 >= end - 1 || pattern.fastCodeAt(start + 1) != ':'.code) return null;
			start += 2;
		}
		return alternation(pattern, start, end - 1);
	}

	/**
	 * First-byte set of the escape `\<c>`.
	 *
	 * Only `\d` and `\w` expand — `\s` is an open Unicode set in ECMAScript
	 * and every other alphanumeric escape is a class, a code escape (`\xNN`,
	 * `\uNNNN`, `\cX`, `\p{…}`) or a backreference, none of which this reads.
	 * A non-alphanumeric escape is an identity escape and answers its own
	 * character, which is what classifies `\.` and `\$` heads.
	 */
	private static function escapeBytes(c: Int): Null<Array<Int>> {
		return switch c {
			case 'd'.code: range('0'.code, '9'.code);
			case 'w'.code:
				range('0'.code, '9'.code).concat(range('A'.code, 'Z'.code)).concat(['_'.code]).concat(range('a'.code, 'z'.code));
			case 'n'.code: ['\n'.code];
			case 't'.code: ['\t'.code];
			case 'r'.code: ['\r'.code];
			case 'f'.code: [FORM_FEED];
			case 'v'.code: [VERTICAL_TAB];
			case _:
				isWordChar(c) ? null : [c];
		};
	}

	/**
	 * Members of the character class `pattern[from...to)` — the span between
	 * the brackets. A NEGATED class answers `null`: its member set is the
	 * complement, which is neither small nor knowable from the source alone.
	 */
	private static function classBytes(pattern: String, from: Int, to: Int): Null<Array<Int>> {
		if (from >= to || pattern.fastCodeAt(from) == '^'.code) return null;
		final codes: Array<Int> = [];
		var i: Int = from;
		while (i < to) {
			final member: Null<Array<Int>> = classMember(pattern, i, to);
			if (member == null) return null;
			final width: Int = pattern.fastCodeAt(i) == '\\'.code ? 2 : 1;
			final afterMember: Int = i + width;
			// `a-z` is a range only when a member follows the `-`; a trailing
			// `-` (as in `[a-]`) is an ordinary member.
			if (member.length == 1 && afterMember + 1 < to && pattern.fastCodeAt(afterMember) == '-'.code) {
				final hiAt: Int = afterMember + 1;
				final hi: Null<Array<Int>> = classMember(pattern, hiAt, to);
				if (hi == null || hi.length != 1) return null;
				if (hi[0] < member[0]) return null;
				if (!absorb(codes, range(member[0], hi[0]))) return null;
				i = hiAt + (pattern.fastCodeAt(hiAt) == '\\'.code ? 2 : 1);
				continue;
			}
			if (!absorb(codes, member)) return null;
			i = afterMember;
		}
		return codes.length == 0 ? null : codes;
	}

	/** One character-class member at `at` — an escape or a bare character. */
	private static function classMember(pattern: String, at: Int, to: Int): Null<Array<Int>> {
		final c: Int = pattern.fastCodeAt(at);
		if (c != '\\'.code) return [c];
		final esc: Int = at + 1 < to ? pattern.fastCodeAt(at + 1) : -1;
		return esc < 0 ? null : escapeBytes(esc);
	}

	/**
	 * Merge `add` into `into`, deduped. `false` when `add` is `null` or holds
	 * a code above `MAX_BYTE`, either of which makes the whole answer `null`
	 * at every caller. The partially-filled `into` never escapes, because
	 * every caller turns `false` into `null` on the spot.
	 *
	 * Every code in a finished answer passes through here: `of` goes through
	 * `alternation`, and `alternation` absorbs every alternative's set.
	 */
	private static function absorb(into: Array<Int>, add: Null<Array<Int>>): Bool {
		if (add == null) return false;
		for (code in add) {
			if (code > MAX_BYTE) return false;
			if (!into.contains(code)) into.push(code);
		}
		return true;
	}

	/** The codes `lo`…`hi` inclusive — a character-class range, or one `\d` / `\w` block. */
	private static function range(lo: Int, hi: Int): Array<Int> {
		return [for (c in lo ... hi + 1) c];
	}

	/**
	 * `[A-Za-z0-9]` — the escapes this refuses to read. Every alphanumeric
	 * escape is a class (`\s`, `\S`, `\W`), a code escape (`\xNN`, `\uNNNN`,
	 * `\cX`, `\p{…}`, `\0`) or a backreference; a NON-alphanumeric one is an
	 * identity escape and answers its own character.
	 */
	private static function isWordChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}

}
