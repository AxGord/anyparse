package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a comment (line, block, or doc comment) that contains a NON-LATIN LETTER —
 * a Cyrillic, CJK, Arabic, Hebrew, Hangul, or Japanese-kana character. The user's
 * rule: all code comments and documentation must be in English only. `Severity.Info`.
 *
 * ## Report-only — no autofix
 *
 * `fix` yields no edits: translating a comment into English is a human task, not a
 * mechanical rewrite, so the check only surfaces the offending comments.
 *
 * ## Detection
 *
 * A pure comment-token scan (no parse needed) over `RefactorSupport.collectCommentTokens`,
 * which is string-aware — a non-Latin character inside a STRING literal is never visited
 * (it is legal data). Each token is scanned for a code UNIT in a well-known non-Latin
 * letter block (Cyrillic U+0400..U+052F, Hebrew, Arabic, Hangul, kana, CJK); the FIRST
 * such unit yields ONE finding for the whole token (not one per character), spanned at
 * that unit, with a short single-line excerpt around it.
 *
 * All blocks are BMP, so scanning UTF-16 code units suffices (no surrogate decoding);
 * astral-plane CJK extensions are out of scope. GREEK is deliberately excluded: its
 * dominant use in code comments is mathematical / symbolic (this codebase tags anchors
 * with the omega letter), so flagging it would be almost all false positives. Latin
 * script with accents (e-acute, u-umlaut, n-tilde) is Latin, not a separate script, and
 * is left alone — so attribution names stay unflagged. Emoji, box-drawing, arrows, and
 * typographic punctuation are not letters and never flag.
 */
@:nullSafety(Strict)
final class EnglishComments implements Check {

	/** Inclusive [lo, hi] UTF-16 code-unit bounds of the non-Latin letter blocks flagged (all BMP). */
	private static final BLOCKS: Array<{ lo: Int, hi: Int }> = [
		{ lo: 0x0400, hi: 0x052F }, // Cyrillic + Cyrillic Supplement
		{ lo: 0x0590, hi: 0x05FF }, // Hebrew
		{ lo: 0x0600, hi: 0x06FF }, // Arabic
		{ lo: 0x1100, hi: 0x11FF }, // Hangul Jamo
		{ lo: 0x3040, hi: 0x30FF }, // Hiragana + Katakana
		{ lo: 0x3400, hi: 0x4DBF }, // CJK Extension A
		{ lo: 0x4E00, hi: 0x9FFF }, // CJK Unified Ideographs
		{ lo: 0xAC00, hi: 0xD7AF }
	];

	/** Lowest flagged code unit; below it (ASCII, Latin-1, Latin-extended, Greek) a char is never a hit — fast reject. */
	private static inline final FIRST_NON_LATIN: Int = 0x0400;

	/** Maximum code units in a finding's excerpt. */
	private static inline final EXCERPT_LEN: Int = 30;

	public function new() {}

	public function id(): String {
		return 'english-comments';
	}

	public function description(): String {
		return 'a comment containing a non-Latin letter (Cyrillic, CJK, Arabic, ...) — comments must be English only';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) scan(violations, entry.file, entry.source);
		return violations;
	}

	/** Report-only — translating a comment into English is a human task, not a mechanical rewrite. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Scan every comment token in `source`, flagging the first non-Latin letter in each. */
	private static function scan(out: Array<Violation>, file: String, source: String): Void {
		for (tok in RefactorSupport.collectCommentTokens(source)) {
			final at: Int = firstNonLatinLetter(source, tok.from, tok.to);
			if (at >= 0) out.push({
				file: file,
				span: new Span(at, at + 1),
				rule: 'english-comments',
				severity: Severity.Info,
				message: 'non-Latin letter in comment: ${excerpt(source, at, tok.to)}'
			});
		}
	}

	/** The index of the first UTF-16 code unit in `[from, to)` that is a non-Latin letter, or -1. */
	private static function firstNonLatinLetter(source: String, from: Int, to: Int): Int {
		for (i in from ... to) if (isNonLatinLetter(StringTools.fastCodeAt(source, i))) return i;
		return -1;
	}

	/** Whether code unit `c` falls in one of the flagged non-Latin letter blocks. */
	private static function isNonLatinLetter(c: Int): Bool {
		if (c < FIRST_NON_LATIN) return false;
		return BLOCKS.exists(b -> c >= b.lo && c <= b.hi);
	}

	/** A single-line excerpt of up to `EXCERPT_LEN` code units from `at`, tabs/newlines flattened to spaces. */
	private static function excerpt(source: String, at: Int, to: Int): String {
		final end: Int = at + EXCERPT_LEN < to ? at + EXCERPT_LEN : to;
		final buf: StringBuf = new StringBuf();
		for (i in at ... end) {
			final c: Int = StringTools.fastCodeAt(source, i);
			buf.addChar(c == '\n'.code || c == '\r'.code || c == '\t'.code ? ' '.code : c);
		}
		return StringTools.trim(buf.toString());
	}

}
