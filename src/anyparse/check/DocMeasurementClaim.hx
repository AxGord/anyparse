package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
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
 * time, an abbreviated commit hash, a slice or backlog id, a before-and-after pair of numbers,
 * the verb a reading is recorded with standing beside a number, or a sentence pinning its claim
 * to the state of this repository. `Severity.Info`.
 *
 * A reading describes one tree at one moment, and the code it sits in outlives that moment. The
 * commit message and the project ledger keep the numbers; the comment keeps the conclusion in a
 * phrase. Prose is the one thing in a source tree nothing else reads, which is why the policy
 * needs a rule at all.
 *
 * ## A number is not a reading — what the shapes are for
 *
 * A bare number is never a marker. A doc naming the code's own constant — a minimum statement
 * count, a configured maximum, a language floor — states a contract, and a rule that flagged
 * digits would report every one of them. Each shape therefore asks for something a contract
 * does not have: a unit beside the number, an identifier only a repository issues, a delta
 * between two values, or the recording verb with a number on its line.
 *
 * ## Two exemptions
 *
 *  - a REFERENCE rather than a record: a marker inside a path or a URL, and a doc-tag line that
 *    points at one. A pointer to where the numbers live is exactly what this rule asks prose to
 *    leave behind, so flagging it would contradict the rule's own advice.
 *  - a fixture's own contract sentence in `test/` — that it was red or green at the base commit,
 *    or which shape discriminates it. Those sentences carry no unit, no id and no hash, so the
 *    shape set exempts them by construction and no code here names them. A commit hash written
 *    beside one IS flagged, deliberately: the hash is the part that goes stale.
 *
 * A string literal is never visited — the seam is the comment scan, so a hash or a duration
 * inside a fixture's source string is data, not prose.
 *
 * ## Off by default, and no autofix
 *
 * `DefaultOff`, because what belongs in a comment is a project's own policy and a project that
 * has not declared one should not inherit this one's; a project opts in through `apqlint.json`.
 * The `fix` seam yields nothing, because the sentence that survives the deletion is a judgement.
 */
@:nullSafety(Strict)
final class DocMeasurementClaim implements Check implements DefaultOff implements NoAutofix {

	/** This check's `id()`, and the `rule` every finding carries. */
	private static inline final RULE_ID: String = 'doc-measurement-claim';

	/** How many code units of the offending comment travel in the message. */
	private static inline final EXCERPT_LEN: Int = 44;

	/** The abbreviated length a commit hash is written at. */
	private static inline final HASH_LENGTH: Int = 8;

	/** The digits a slice id carries, and the fewest a backlog id does. */
	private static inline final SLICE_DIGITS: Int = 3;

	/** The most digits a backlog id carries. */
	private static inline final BACKLOG_DIGITS: Int = 4;

	/** The code unit an arrow between two values is drawn with. */
	private static inline final ARROW: Int = 0x2192;

	/** The arrow prose types where the drawn one is unavailable. */
	private static inline final TYPED_ARROW: String = '->';

	/** The word standing between a count and the total it was counted out of. */
	private static inline final RATIO_WORD: String = ' of ';

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
		return 'a comment carrying a reading of a tree — a duration, a commit hash, a slice id, a before-and-after pair';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final source: String = entry.source;
			for (unit in SourceComments.collectCommentUnits(source, plugin.lexicalRegions(source))) {
				final reading: Null<Reading> = firstReading(source, unit.from, unit.to);
				if (reading != null) violations.push({
					file: entry.file,
					span: new Span(reading.at, reading.to),
					rule: RULE_ID,
					severity: Severity.Info,
					message: '${reading.shape} in a comment: ${SourceComments.excerptLine(source, reading.at, unit.to, EXCERPT_LEN)}$ADVICE'
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

	/** `code` as its lower-case self, for the ASCII letters every marker is written in. */
	private static inline function lowered(code: Int): Int {
		return code >= 'A'.code && code <= 'Z'.code ? code + ('a'.code - 'A'.code) : code;
	}

	/** Whether `code` is an ASCII decimal digit. */
	private static inline function isDigit(code: Int): Bool {
		return code >= '0'.code && code <= '9'.code;
	}

	/** Whether `code` separates a number from its decimal group, in either convention. */
	private static inline function isDecimalSeparator(code: Int): Bool {
		return code == '.'.code || code == ','.code;
	}

	/** Whether `code` may appear inside an identifier. */
	private static inline function isIdentChar(code: Int): Bool {
		return isDigit(code) || (code >= 'a'.code && code <= 'z'.code) || (code >= 'A'.code && code <= 'Z'.code) || code == '_'.code;
	}

	/** Whether `code` is drawn from a comment's own opener or gutter rather than from its prose. */
	private static inline function isGutter(code: Int): Bool {
		return code == ' '.code || code == '\t'.code || code == '*'.code || code == '/'.code;
	}

	/**
	 * The first reading in `[from, to)`, or null. ONE finding per comment: a block carrying
	 * several of them says the same thing about the same prose, and the reader is being asked to
	 * rewrite the block either way.
	 */
	private static function firstReading(source: String, from: Int, to: Int): Null<Reading> {
		for (at in from ... to) {
			final reading: Null<Reading> = readingAt(source, from, to, at);
			if (reading != null && !insideReference(source, from, to, reading.at)) return reading;
		}
		return null;
	}

	/** The reading starting at `at`, or null — the shapes in the order they are cheapest to refuse. */
	private static function readingAt(source: String, from: Int, to: Int, at: Int): Null<Reading> {
		if (isTokenStart(source, from, at)) {
			final duration: Null<Reading> = durationAt(source, to, at);
			if (duration != null) return duration;
			final ratio: Null<Reading> = ratioAt(source, to, at);
			if (ratio != null) return ratio;
			final token: Int = tokenEnd(source, to, at);
			if (isCommitHash(source, at, token)) return { at: at, to: token, shape: 'a commit hash' };
			if (isWorkId(source, at, token)) return { at: at, to: token, shape: 'a slice or backlog id' };
			if (isRecordingVerb(source, at, token) && lineHasDigit(source, from, to, at))
				return { at: at, to: token, shape: 'a recording verb beside a number' };
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
		final digits: Int = numberEnd(source, to, at);
		if (digits == at) return null;
		final unit: Int = timeUnitEnd(source, to, digits);
		return unit < 0 ? null : { at: at, to: unit, shape: 'a duration' };
	}

	/**
	 * The count-against-a-total starting at `at`, or null. Both sides must be numbers: a census of
	 * one tree is written that way, while a contract counts nothing out of anything.
	 */
	private static function ratioAt(source: String, to: Int, at: Int): Null<Reading> {
		final digits: Int = numberEnd(source, to, at);
		if (digits == at || !matchesIgnoringCase(source, to, digits, RATIO_WORD)) return null;
		final total: Int = numberAfter(source, to, digits + RATIO_WORD.length);
		return total < 0 ? null : { at: at, to: total, shape: 'a count against a total' };
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
		return REFERENCE_TAGS.exists(tag -> matchesIgnoringCase(source, to, i, tag));
	}

	/** Whether a token starts at `at` — nothing an identifier may carry stands before it. */
	private static function isTokenStart(source: String, from: Int, at: Int): Bool {
		return at == from || !isIdentChar(source.fastCodeAt(at - 1));
	}

	/** Where the identifier token at `at` ends; `at` itself when none starts there. */
	private static function tokenEnd(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && isIdentChar(source.fastCodeAt(i))) i++;
		return i;
	}

	/** Where the number at `at` ends, one decimal group included; `at` itself when none starts there. */
	private static function numberEnd(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && isDigit(source.fastCodeAt(i))) i++;
		if (i == at) return at;
		if (i + 1 < to && isDecimalSeparator(source.fastCodeAt(i)) && isDigit(source.fastCodeAt(i + 1))) {
			i++;
			while (i < to && isDigit(source.fastCodeAt(i))) i++;
		}
		return i;
	}

	/**
	 * Where the time unit written after the number ending at `from` closes, or -1 when there is none.
	 * Read case-sensitively: an upper-case second is a NAME in prose (a pipeline pass), never a unit.
	 */
	private static function timeUnitEnd(source: String, to: Int, from: Int): Int {
		var i: Int = from;
		if (i < to && source.fastCodeAt(i) == ' '.code) i++;
		final end: Int = tokenEnd(source, to, i);
		if (end == i) return -1;
		for (unit in TIME_UNITS) if (unit == source.substring(i, end)) return end;
		return -1;
	}

	/** Where the arrow at `at` ends, or -1 when none starts there — both the drawn and the typed one. */
	private static function arrowEnd(source: String, to: Int, at: Int): Int {
		return if (source.fastCodeAt(at) == ARROW)
			at + 1
		else if (matchesIgnoringCase(source, to, at, TYPED_ARROW))
			at + TYPED_ARROW.length
		else
			-1;
	}

	/** Where the number standing just before `at` begins, or -1 when a non-number does. */
	private static function numberBefore(source: String, from: Int, at: Int): Int {
		var i: Int = at;
		while (i > from && source.fastCodeAt(i - 1) == ' '.code) i--;
		if (i == from || !isDigit(source.fastCodeAt(i - 1))) return -1;
		while (i > from && (isDigit(source.fastCodeAt(i - 1)) || isDecimalSeparator(source.fastCodeAt(i - 1)))) i--;
		return isDigit(source.fastCodeAt(i)) ? i : i + 1;
	}

	/** Where the number standing just after `at` ends, or -1 when a non-number does. */
	private static function numberAfter(source: String, to: Int, at: Int): Int {
		var i: Int = at;
		while (i < to && source.fastCodeAt(i) == ' '.code) i++;
		final end: Int = numberEnd(source, to, i);
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
			if (isDigit(c))
				digits++;
			else if (c >= 'a'.code && c <= 'f'.code)
				letters++;
			else
				return false;
		}
		return digits > 0 && letters > 0;
	}

	/** Whether the token `[at, end)` is a slice id or a backlog id — the ids this project issues. */
	private static function isWorkId(source: String, at: Int, end: Int): Bool {
		final head: Int = source.fastCodeAt(at);
		final digits: Int = end - at - 1;
		if (head != 'S'.code && head != 'T'.code) return false;
		if (digits < SLICE_DIGITS || digits > BACKLOG_DIGITS) return false;
		if (head == 'S'.code && digits != SLICE_DIGITS) return false;
		for (i in at + 1...end) if (!isDigit(source.fastCodeAt(i))) return false;
		return true;
	}

	/** Whether the token `[at, end)` is the verb a reading is recorded with. */
	private static function isRecordingVerb(source: String, at: Int, end: Int): Bool {
		return RECORDING_VERBS.exists(verb -> tokenEqualsIgnoringCase(source, at, end, verb));
	}

	/** Where the phrase pinning a claim to one repository ends, or `at` when none starts there. */
	private static function scopePhraseEnd(source: String, to: Int, at: Int): Int {
		for (phrase in SCOPE_PHRASES) if (matchesIgnoringCase(source, to, at, phrase)) return at + phrase.length;
		return at;
	}

	/** Whether a digit stands anywhere on the comment line holding `at`. */
	private static function lineHasDigit(source: String, from: Int, to: Int, at: Int): Bool {
		var end: Int = at;
		while (end < to && source.fastCodeAt(end) != '\n'.code) end++;
		for (i in lineStart(source, from, at) ... end) if (isDigit(source.fastCodeAt(i))) return true;
		return false;
	}

	/** Where the comment line holding `at` begins, never past the comment's own start. */
	private static function lineStart(source: String, from: Int, at: Int): Int {
		var i: Int = at;
		while (i > from && source.fastCodeAt(i - 1) != '\n'.code) i--;
		return i;
	}

	/** Whether the token `[at, end)` reads as `word`, case ignored. */
	private static function tokenEqualsIgnoringCase(source: String, at: Int, end: Int, word: String): Bool {
		return end - at == word.length && matchesIgnoringCase(source, end, at, word);
	}

	/** Whether `word` stands at `at`, case ignored and never reading past `to`. */
	private static function matchesIgnoringCase(source: String, to: Int, at: Int, word: String): Bool {
		if (at + word.length > to) return false;
		for (i in 0...word.length) if (lowered(source.fastCodeAt(at + i)) != lowered(word.fastCodeAt(i))) return false;
		return true;
	}

}
