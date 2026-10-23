package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * One reading found inside a comment: the bytes it covers, and the shape that identifies it.
 */
private typedef Reading = {
	final at: Int;
	final to: Int;
	final shape: String;
};

/**
 * Flags a comment carrying a READING of a tree rather than a contract — a number with a unit of
 * time, a share written with the percent sign, an abbreviated commit hash, a slice or backlog id, a
 * census count (a number, in digits or words, before a noun only a run over a tree counts), a
 * before-and-after pair of numbers, the verb a reading is recorded with, or a sentence pinning its
 * claim to the state of this repository. `Severity.Info`.
 *
 * A reading describes one tree at one moment, and the code it sits in outlives that moment. The
 * commit message and the project ledger keep the numbers; the comment keeps the conclusion in a
 * phrase. Prose is the one thing nothing else in a source tree reads, hence a rule for it.
 *
 * ## A number is not a reading — what the shapes are for
 *
 * A bare number is never a marker. A doc naming the code's own constant — a minimum statement
 * count, a configured maximum, a language floor — states a contract, and a rule that flagged digits
 * would report every one of them. Each shape therefore asks for something a contract does not have:
 * a unit or a census noun beside the number, an identifier only a repository issues, a delta between
 * two values, or the recording verb where it introduces a claim.
 *
 * ## What stays silent
 *
 *  - a REFERENCE rather than a record: a marker inside a path or a URL, and a doc-tag line that
 *    points at one. A pointer to where the numbers live is what this rule asks prose to leave
 *    behind, so flagging it would contradict the rule's own advice.
 *  - a fixture's own contract sentence in `test/` — red or green at the base commit, or which shape
 *    discriminates it. Those carry no unit, no id and no hash, so the shape set exempts them by
 *    construction. A commit hash beside one IS flagged: the hash is the part that goes stale.
 *  - the percent sign read as the REMAINDER operator: prose showing arithmetic writes a number on
 *    its right, and no share is taken from a line that does.
 *  - the recording verb MID-CLAUSE, which is this project's own vocabulary for how a width or a
 *    region is obtained; only the verb opening a clause records something.
 *  - a string literal, never visited at all: the seam is the comment scan, so a hash or a duration
 *    inside a fixture's source string is data, not prose.
 *
 * ## Off by default, and no autofix
 *
 * `DefaultOff`, because what belongs in a comment is a project's own policy and a project that has
 * not declared one should not inherit this one's; a project opts in through `apqlint.json`. The
 * `fix` seam yields nothing, because the sentence that survives the deletion is a judgement.
 */
@:nullSafety(Strict)
final class DocMeasurementClaim implements Check implements DefaultOff implements NoAutofix {

	/** This check's `id()`, and the `rule` every finding carries. */
	private static inline final RULE_ID: String = 'doc-measurement-claim';

	/** How many code units of the offending comment travel in the message. */
	private static inline final EXCERPT_LEN: Int = 44;

	/** The abbreviated length a commit hash is written at. */
	private static inline final HASH_LENGTH: Int = 8;

	/** The most digits a slice id carries; an id with fewer is short, and is read only outside code. */
	private static inline final SLICE_DIGITS: Int = 3;

	/** The fewest digits a slice or backlog id is read with; a single digit is a type parameter's name. */
	private static inline final SHORT_ID_DIGITS: Int = 2;

	/** The most digits a backlog id carries. */
	private static inline final BACKLOG_DIGITS: Int = 4;

	/** The code unit an arrow between two values is drawn with. */
	private static inline final ARROW: Int = 0x2192;

	/** The arrow prose types where the drawn one is unavailable. */
	private static inline final TYPED_ARROW: String = '->';

	/** The dash a sentence is broken with, beside the ASCII one. */
	private static inline final EM_DASH: Int = 0x2014;

	/** The word standing between a count and the total it was counted out of. */
	private static inline final RATIO_WORD: String = ' of ';

	/** The code unit inline code is fenced with in prose. */
	private static inline final BACKTICK: Int = '`'.code;

	/** Bytes of the opener no comment word starts before — a scan reaching past it reads code. */
	private static inline final OPENER_LENGTH: Int = 2;

	/** What every finding asks for, once the shape has been named. */
	private static inline final ADVICE: String =
		' — a reading is of one tree at one moment: keep the conclusion in a phrase, and leave the numbers to the commit message or the ledger';

	/** The unit tokens a duration is written with. */
	private static final TIME_UNITS: Array<String> = ['ns', 'us', 'ms', 's', 'min'];

	/** The verb a reading is recorded with, in the spellings prose uses. */
	private static final RECORDING_VERBS: Array<String> = ['measured', 'measurement', 'measurements'];

	/** The phrases that pin a claim to one repository at one moment, lower case. */
	private static final SCOPE_PHRASES: Array<String> = ['on this tree', 'in this tree', 'of this tree'];

	/** Doc tags whose line points AT a record instead of carrying one. */
	private static final REFERENCE_TAGS: Array<String> = ['@see', '@link'];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a comment carrying a reading of a tree — a duration, a commit hash, a slice id, a census count, a before-and-after pair';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final source: String = entry.source;
			for (unit in SourceComments.collectCommentUnits(source, plugin.lexicalRegions(source))) {
				final found: Array<Reading> = readings(source, unit.from, unit.to);
				if (found.length == 0) continue;
				final first: Reading = found[0];
				final plural: String = found.length == 1 ? '' : 's';
				final excerpt: String = SourceComments.excerptLine(source, first.at, unit.to, EXCERPT_LEN);
				violations.push({
					file: entry.file,
					span: new Span(first.at, first.to),
					rule: RULE_ID,
					severity: Severity.Info,
					message: '${first.shape} in a comment (${found.length} reading$plural): $excerpt$ADVICE'
				});
			}
		}
		return violations;
	}

	/** No edit: which sentence survives the numbers is a judgement, not a rewrite. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'lifting the numbers out leaves a sentence only their author can finish — what the reading concluded is not in them';
	}

	/** Whether `code` is drawn from a comment's own opener or gutter rather than from its prose. */
	private static inline function isGutter(code: Int): Bool {
		return code == ' '.code || code == '\t'.code || code == '*'.code || code == '/'.code;
	}

	/**
	 * Every reading in `[from, to)`, in position order, with overlapping ones folded into one: a
	 * chain of arrows records ONE progression, not a reading per arrow.
	 *
	 * Still ONE finding per comment, anchored at the first — the reader is being asked to rewrite
	 * the whole block either way — but how many the block holds travels in the message, because a
	 * long block with several of them reads as one line of the report.
	 */
	private static function readings(source: String, from: Int, to: Int): Array<Reading> {
		final found: Array<Reading> = [];
		for (at in from ... to) {
			final reading: Null<Reading> = readingAt(source, from, to, at);
			if (reading == null || insideReference(source, from, to, reading.at)) continue;
			final last: Int = found.length - 1;
			if (last < 0 || reading.at >= found[last].to)
				found.push(reading);
			else if (reading.to > found[last].to)
				found[last] = { at: found[last].at, to: reading.to, shape: found[last].shape };
		}
		return found;
	}

	/** The reading starting at `at`, or null — the shapes in the order they are cheapest to refuse. */
	private static function readingAt(source: String, from: Int, to: Int, at: Int): Null<Reading> {
		if (isTokenStart(source, from, at)) {
			final duration: Null<Reading> = durationAt(source, to, at);
			if (duration != null) return duration;
			final ratio: Null<Reading> = ratioAt(source, to, at);
			if (ratio != null) return ratio;
			final share: Null<Reading> = percentAt(source, from, to, at);
			if (share != null) return share;
			final census: Null<Reading> = censusAt(source, from, to, at);
			if (census != null) return census;
			final token: Int = ProseNumbers.tokenEnd(source, to, at);
			if (isCommitHash(source, at, token)) return { at: at, to: token, shape: 'a commit hash' };
			final id: Int = workIdEnd(source, from, to, at, token);
			if (id > at) return { at: at, to: id, shape: 'a slice or backlog id' };
			if (isRecordingVerb(source, at, token)) {
				if (lineHasDigit(source, from, to, at)) return { at: at, to: token, shape: 'a recording verb beside a number' };
				if (opensClause(source, from, at)) return { at: at, to: token, shape: 'a recording verb opening a claim' };
			}
			final phrase: Int = scopePhraseEnd(source, to, at);
			if (phrase > at) return { at: at, to: phrase, shape: 'a claim about the state of this repository' };
		}
		return deltaAt(source, from, to, at);
	}

	/**
	 * The duration starting at `at`, or null. The UNIT is the whole discrimination: a number
	 * standing alone is a quantity the code itself declares, and this rule never reads one.
	 */
	private static function durationAt(source: String, to: Int, at: Int): Null<Reading> {
		final digits: Int = ProseNumbers.numberEnd(source, to, at);
		if (digits == at) return null;
		final unit: Int = timeUnitEnd(source, to, digits);
		return unit < 0 ? null : { at: at, to: unit, shape: 'a duration' };
	}

	/**
	 * The count-against-a-total starting at `at`, or null. Both sides must be numbers: a census of
	 * one tree is written that way, while a contract counts nothing out of anything.
	 */
	private static function ratioAt(source: String, to: Int, at: Int): Null<Reading> {
		final digits: Int = ProseNumbers.numberEnd(source, to, at);
		if (digits == at || !ProseNumbers.matchesIgnoringCase(source, to, digits, RATIO_WORD)) return null;
		final total: Int = numberAfter(source, to, digits + RATIO_WORD.length);
		return total < 0 ? null : { at: at, to: total, shape: 'a count against a total' };
	}

	/**
	 * The share written with the percent sign starting at `at`, or null. The sign is the unit, just
	 * as a duration's is.
	 *
	 * A line that ALSO writes the sign with a number on its right is showing the remainder
	 * operator, and no share is taken from arithmetic: prose about precedence writes both, and the
	 * share it looks like was never claimed.
	 */
	private static function percentAt(source: String, from: Int, to: Int, at: Int): Null<Reading> {
		final digits: Int = ProseNumbers.numberEnd(source, to, at);
		if (digits == at) return null;
		var sign: Int = digits;
		if (sign < to && source.fastCodeAt(sign) == ' '.code) sign++;
		if (sign >= to || source.fastCodeAt(sign) != '%'.code) return null;
		var end: Int = at;
		while (end < to && source.fastCodeAt(end) != '\n'.code) end++;
		for (i in lineStart(source, from, at) ... end) if (source.fastCodeAt(i) == '%'.code && numberAfter(source, end, i + 1) >= 0)
			return null;
		return { at: at, to: sign + 1, shape: 'a percentage share' };
	}

	/**
	 * Whether the word at `at` OPENS a clause — it is the comment's own first word, it stands
	 * against an opening parenthesis, or whitespace separates it from the punctuation that closed
	 * the clause before it.
	 *
	 * Mid-clause the recording verb is this project's ordinary vocabulary for how a width or a
	 * region is obtained, and that vocabulary states a contract; only where the verb opens a
	 * clause does it introduce a claim. Whitespace is required so that a prefix glued on with a
	 * hyphen stays inside its word, and a hyphen that ends its own line is a word broken by the
	 * wrap rather than a break in the prose.
	 */
	private static function opensClause(source: String, from: Int, at: Int): Bool {
		if (at > from && source.fastCodeAt(at - 1) == '('.code) return true;
		var i: Int = at;
		var wrapped: Bool = false;
		while (i > from && (isGutter(source.fastCodeAt(i - 1)) || source.fastCodeAt(i - 1) == '\n'.code)) {
			if (source.fastCodeAt(i - 1) == '\n'.code) wrapped = true;
			i--;
		}
		if (i == at) return false;
		if (i <= from + OPENER_LENGTH) return true;
		return switch source.fastCodeAt(i - 1) {
			case '('.code, '.'.code, ':'.code, ';'.code, '!'.code, '?'.code, EM_DASH: true;
			case '-'.code: !wrapped;
			case _: false;
		};
	}

	/**
	 * The before-and-after pair whose arrow starts at `at`, or null. DIGITS on both sides are the
	 * whole discrimination: an arrow between anything else is this language's function type, its
	 * lambda, or a map entry, and all three are ordinary prose about code.
	 */
	private static function deltaAt(source: String, from: Int, to: Int, at: Int): Null<Reading> {
		final arrow: Int = arrowEnd(source, to, at);
		if (arrow < 0) return null;
		final left: Int = numberBefore(source, from, at);
		final right: Int = numberAfter(source, to, arrow);
		return left < 0 || right < 0 ? null : { at: left, to: right, shape: 'a before-and-after pair' };
	}

	/**
	 * Whether the reading at `at` POINTS AT a record instead of carrying one — it sits inside a
	 * path or a URL, or on a doc-tag line.
	 *
	 * Leaving a pointer behind is what this rule asks prose to do, so a rule that flagged the
	 * pointer would contradict its own advice. A leading comment opener is stripped off the word
	 * first: a marker glued to a `//` would otherwise read as a path because of the opener alone.
	 */
	private static function insideReference(source: String, from: Int, to: Int, at: Int): Bool {
		var start: Int = at;
		while (start > from + OPENER_LENGTH && !SourceText.isSpace(source.fastCodeAt(start - 1))) start--;
		var end: Int = at;
		while (end < to && !SourceText.isSpace(source.fastCodeAt(end))) end++;
		while (start < end && isGutter(source.fastCodeAt(start))) start++;
		for (i in start ... end) {
			final c: Int = source.fastCodeAt(i);
			if (c == '/'.code || c == '\\'.code) return true;
		}
		return onReferenceTagLine(source, from, to, at);
	}

	/** Whether the line holding `at` opens, past its gutter, with a doc tag that names a record. */
	private static function onReferenceTagLine(source: String, from: Int, to: Int, at: Int): Bool {
		var i: Int = lineStart(source, from, at);
		while (i < to && isGutter(source.fastCodeAt(i))) i++;
		return REFERENCE_TAGS.exists(tag -> ProseNumbers.matchesIgnoringCase(source, to, i, tag));
	}

	/** Whether a token starts at `at` — nothing an identifier may carry stands before it. */
	private static function isTokenStart(source: String, from: Int, at: Int): Bool {
		return at == from || !SourceText.isIdentChar(source.fastCodeAt(at - 1));
	}

	/**
	 * Where the time unit written after the number ending at `from` closes, or -1 when there is none.
	 * Read case-sensitively: an upper-case second is a NAME in prose (a pipeline pass), never a unit.
	 */
	private static function timeUnitEnd(source: String, to: Int, from: Int): Int {
		var i: Int = from;
		if (i < to && source.fastCodeAt(i) == ' '.code) i++;
		final end: Int = ProseNumbers.tokenEnd(source, to, i);
		if (end == i) return -1;
		for (unit in TIME_UNITS) if (unit == source.substring(i, end)) return end;
		return -1;
	}

	/** Where the arrow at `at` ends, or -1 when none starts there — both the drawn and the typed one. */
	private static function arrowEnd(source: String, to: Int, at: Int): Int {
		return if (source.fastCodeAt(at) == ARROW)
			at + 1
		else if (ProseNumbers.matchesIgnoringCase(source, to, at, TYPED_ARROW))
			at + TYPED_ARROW.length
		else
			-1;
	}

	/** Where the number standing just before `at` begins, or -1 when a non-number does. */
	private static function numberBefore(source: String, from: Int, at: Int): Int {
		var i: Int = at;
		while (i > from && source.fastCodeAt(i - 1) == ' '.code) i--;
		if (i == from || !ProseNumbers.isDigit(source.fastCodeAt(i - 1))) return -1;
		while (i > from && (ProseNumbers.isDigit(source.fastCodeAt(i - 1)) || ProseNumbers.isDecimalSeparator(source.fastCodeAt(i - 1))))
			i--;
		return ProseNumbers.isDigit(source.fastCodeAt(i)) ? i : i + 1;
	}

	/** Where the number standing just after `at` ends, or -1 when a non-number does. */
	private static function numberAfter(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && source.fastCodeAt(i) == ' '.code) i++;
		final end: Int = ProseNumbers.numberEnd(source, to, i);
		return end == i ? -1 : end;
	}

	/**
	 * Whether the token `[at, end)` is an abbreviated commit hash.
	 *
	 * The mixture is what makes it one: a token of that length drawn only from digits is a
	 * number, and one drawn only from letters is a word.
	 */
	private static function isCommitHash(source: String, at: Int, end: Int): Bool {
		if (end - at != HASH_LENGTH) return false;
		var digits: Int = 0;
		var letters: Int = 0;
		for (i in at ... end) {
			final c: Int = source.fastCodeAt(i);
			if (ProseNumbers.isDigit(c))
				digits++;
			else if (c >= 'a'.code && c <= 'f'.code)
				letters++;
			else
				return false;
		}
		return digits > 0 && letters > 0;
	}

	/**
	 * Where the slice or backlog id at `[at, end)` ends, a sub-slice suffix (`S10.4`) included, or -1
	 * when the token is not one of the ids this project issues.
	 *
	 * A short id is also how a type parameter is named, so one written as code — fenced in backticks,
	 * or straight after the `:`, `<` or `.` that a type position opens with — is left to the code.
	 */
	private static function workIdEnd(source: String, from: Int, to: Int, at: Int, end: Int): Int {
		final head: Int = source.fastCodeAt(at);
		if (head != 'S'.code && head != 'T'.code) return -1;
		final digits: Int = end - at - 1;
		if (digits < SHORT_ID_DIGITS || digits > (head == 'S'.code ? SLICE_DIGITS : BACKLOG_DIGITS)) return -1;
		for (i in at + 1...end) if (!ProseNumbers.isDigit(source.fastCodeAt(i))) return -1;
		if (digits < SLICE_DIGITS && namesAType(source, from, at)) return -1;
		final sub: Int = end + 1;
		if (sub >= to || source.fastCodeAt(end) != '.'.code || !ProseNumbers.isDigit(source.fastCodeAt(sub))) return end;
		final subEnd: Int = ProseNumbers.tokenEnd(source, to, sub);
		for (i in sub ... subEnd) if (!ProseNumbers.isDigit(source.fastCodeAt(i))) return end;
		return subEnd;
	}

	/** Whether the token at `at` stands where code names a type: in inline code, or after `:`, `<`, `.`. */
	private static function namesAType(source: String, from: Int, at: Int): Bool {
		if (at > from) switch source.fastCodeAt(at - 1) {
			case ':'.code, '<'.code, '.'.code:
				return true;
			case _:
		}
		return insideCodeSpan(source, from, at);
	}

	/** Whether `at` sits inside an inline code span — an odd number of backticks opens its line before it. */
	private static function insideCodeSpan(source: String, from: Int, at: Int): Bool {
		var fences: Int = 0;
		for (i in lineStart(source, from, at) ... at) if (source.fastCodeAt(i) == BACKTICK) fences++;
		return fences % 2 == 1;
	}

	/**
	 * The census count starting at `at`, or null: a count — in digits, or spelled from eleven up —
	 * followed by a noun only a run over a tree counts, or a number typeset with grouped thousands.
	 *
	 * The NOUN is the discrimination, as the unit is a duration's: a contract bounds a dimension of the
	 * code, and no dimension is on the list. A small count is the size of a fixture and is not read; a
	 * count fenced as inline code is quoted data; a bound, a standard's number or one glued to the token
	 * before it is a contract (`ProseNumbers.readsAsContract`).
	 */
	private static function censusAt(source: String, from: Int, to: Int, at: Int): Null<Reading> {
		if (insideCodeSpan(source, from, at)) return null;
		final digits: Int = ProseNumbers.numberEnd(source, to, at);
		if (digits > at) {
			final grouped: Int = ProseNumbers.groupedEnd(source, to, digits);
			if (grouped > digits)
				return ProseNumbers.readsAsContract(source, from, to, at, grouped)
					? null
					: { at: at, to: grouped, shape: 'a census count' };
			if (!ProseNumbers.isCensusSized(source, to, at)) return null;
		}
		final count: Int = digits > at ? digits : ProseNumbers.spelledNumberEnd(source, to, at);
		if (count == at) return null;
		final noun: Int = ProseNumbers.censusNounEnd(source, to, count);
		return noun < 0 || ProseNumbers.readsAsContract(source, from, to, at, noun) ? null : { at: at, to: noun, shape: 'a census count' };
	}

	/** Whether the token `[at, end)` is the verb a reading is recorded with. */
	private static function isRecordingVerb(source: String, at: Int, end: Int): Bool {
		return RECORDING_VERBS.exists(verb -> ProseNumbers.tokenEqualsIgnoringCase(source, at, end, verb));
	}

	/** Where the phrase pinning a claim to one repository ends, or `at` when none starts there. */
	private static function scopePhraseEnd(source: String, to: Int, at: Int): Int {
		for (phrase in SCOPE_PHRASES) if (ProseNumbers.matchesIgnoringCase(source, to, at, phrase)) return at + phrase.length;
		return at;
	}

	/**
	 * Whether a digit stands on the comment line holding `at`, outside inline code: digits in
	 * backticks are code a sentence quotes.
	 */
	private static function lineHasDigit(source: String, from: Int, to: Int, at: Int): Bool {
		var end: Int = at;
		while (end < to && source.fastCodeAt(end) != '\n'.code) end++;
		for (i in lineStart(source, from, at) ... end) if (ProseNumbers.isDigit(source.fastCodeAt(i)) && !insideCodeSpan(source, from, i))
			return true;
		return false;
	}

	/** Where the comment line holding `at` begins, never past the comment's own start. */
	private static function lineStart(source: String, from: Int, at: Int): Int {
		var i: Int = at;
		while (i > from && source.fastCodeAt(i - 1) != '\n'.code) i--;
		return i;
	}

}
