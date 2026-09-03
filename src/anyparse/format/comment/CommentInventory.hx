package anyparse.format.comment;

import anyparse.core.EnvFlag;
import haxe.Exception;

using StringTools;

/**
 * Comment-preservation audit over a writer round trip.
 *
 * The Trivia-mode parser captures comments only at the positions that own
 * a capture slot (statement / member / call-argument boundaries, the Pratt
 * operand stash, the per-construct sidecar slots). A comment in any OTHER
 * seam — `if (/* c *\/ x)`, `return /* r *\/ x;`, `switch (v /* s *\/)`, a
 * type-annotation or class-header interior — is consumed as whitespace and
 * never reaches the AST, so the writer re-emits the construct without it.
 * That is DATA loss: the byte is gone from the user's file.
 *
 * This module is the fail-closed net for the seams that have no slot yet.
 * `firstMissing` compares the comment inventory of the source against the
 * writer's output; a caller that gets a comment back must keep the ORIGINAL
 * bytes rather than write the lossy output. Freezing a file's formatting is
 * recoverable — deleting an author's comment is not.
 *
 * Matching is deliberately loose on WHITESPACE only: the writer legally
 * re-indents block-comment continuation lines, normalises a javadoc close,
 * inserts the `addLineCommentSpace` gap after `//`, and may re-wrap a
 * comment's surroundings. Every one of those is whitespace-level, so both
 * sides are compared with the delimiters, the per-line `*` gutter and ALL
 * whitespace removed. Multiplicity is compared too — losing one of two
 * identical comments is still data loss.
 *
 * What the audit demands OF that scan: it must skip the grammar's string and
 * regex literals, so a `"/* not a comment *\/"` payload never counts as a
 * comment on either side, and it must follow whatever code a literal can nest
 * (for Haxe, a `${…}` interpolation hole). A scan that mis-pairs a nested
 * same-quote literal desynchronises for the rest of the file, which is the one
 * way a real loss could hide from this check.
 *
 * The scan is the CALLER's: `collect` and `firstMissing` take a `CommentScan`,
 * the per-grammar comment lexer, so nothing in this package knows one
 * language's string, interpolation or regex syntax. It used to be Haxe-lexed
 * inline — the Haxe writer was the only consumer, and a grammar-agnostic
 * package was deciding what a comment is for every language. That lexer now
 * sits beside the grammar's other one, as `HaxeLexicalRegions.scanComments`.
 */
@:nullSafety(Strict)
final class CommentInventory {

	/**
	 * Environment switch that declines the guard for the whole process.
	 * Public so the CLI can WARN when it is set: it re-arms comment deletion
	 * on the write paths, not just in the read-only writer probes it exists
	 * for.
	 */
	public static inline final DECLINE_ENV: String = 'APQ_ALLOW_COMMENT_LOSS';

	/** Longest comment head an error message quotes before eliding. */
	private static inline final MESSAGE_WIDTH: Int = 60;

	/** Shortest block comment that carries BOTH delimiters (`/**\/`). */
	private static inline final MIN_CLOSED_BLOCK: Int = 4;

	/** Whether `DECLINE_ENV` declines the comment guard in this process. */
	public static inline function guardDeclined(): Bool return EnvFlag.isSet(DECLINE_ENV);

	/**
	 * The first comment of `source` that `output` does not carry, verbatim
	 * and truncated to one line for a message; `null` when every comment
	 * survived. Comment bodies are compared ignoring the whitespace-level
	 * reformatting the writer is allowed to perform.
	 *
	 * `scan` is the caller's grammar comment lexer — the same one on both
	 * sides, so a difference can only be a lost comment, never a difference
	 * of opinion about what a comment is.
	 */
	public static function firstMissing(source: String, output: String, scan: CommentScan): Null<String> {
		final wanted: Array<String> = collect(source, scan);
		if (wanted.length == 0) return null;
		final have: Map<String, Int> = [];
		for (c in collect(output, scan)) {
			final key: String = normalize(c);
			have[key] = (have[key] ?? 0) + 1;
		}
		for (c in wanted) {
			final key: String = normalize(c);
			final left: Int = have[key] ?? 0;
			if (left == 0) return summarize(c);
			have[key] = left - 1;
		}
		return null;
	}

	/**
	 * Every comment in `src`, verbatim and in source order, as `scan` reports
	 * them — string and regex literals skipped, and whatever else that
	 * grammar's lexer decides.
	 */
	public static function collect(src: String, scan: CommentScan): Array<String> {
		final out: Array<String> = [];
		scan(src, (start: Int, end: Int) -> out.push(src.substring(start, end)));
		return out;
	}

	/** One-line rendering of a comment for an error message. */
	private static function summarize(comment: String): String {
		final newlineIndex: Int = comment.indexOf('\n');
		final head: String = StringTools.rtrim(newlineIndex < 0 ? comment : comment.substring(0, newlineIndex));
		final clipped: String = head.length > MESSAGE_WIDTH ? head.substring(0, MESSAGE_WIDTH) : head;
		return clipped == comment ? clipped : '$clipped ...';
	}

	/**
	 * Comment text stripped to what the writer may NOT change: delimiters,
	 * the per-line `*` gutter and all whitespace removed. Both comment styles
	 * route through the same body pass so the two sides of a comparison can
	 * never drift apart on a normalisation rule.
	 */
	private static function normalize(comment: String): String {
		if (comment.startsWith('//')) return normalizeBody(comment.substring(2));
		// `collect` emits nothing else, so a third shape means the scanner and
		// this function disagree about what a comment token is.
		if (!comment.startsWith('/*')) throw new Exception('not a comment token: `$comment`');
		var end: Int = comment.length;
		// A trailing `*/` (and the `*` of a `**/` close) carries no text. An
		// unterminated `/*/` is shorter than both delimiters together — leave
		// it whole rather than cut past the open.
		if (end >= MIN_CLOSED_BLOCK && comment.endsWith('*/')) end -= 2;
		while (end > 2 && comment.fastCodeAt(end - 1) == '*'.code) end--;
		return normalizeBody(comment.substring(2, end));
	}

	/**
	 * The shared body pass: drop every whitespace character, and the `*` that
	 * opens a continuation line (the javadoc gutter the writer re-indents).
	 */
	private static function normalizeBody(body: String): String {
		final buf: StringBuf = new StringBuf();
		final len: Int = body.length;
		var i: Int = 0;
		var atLineStart: Bool = true;
		while (i < len) {
			final c: Int = body.fastCodeAt(i);
			i++;
			if (c == '\n'.code) {
				atLineStart = true;
				continue;
			}
			if (c == ' '.code || c == '\t'.code || c == '\r'.code) continue;
			if (atLineStart && c == '*'.code) continue;
			atLineStart = false;
			buf.addChar(c);
		}
		return buf.toString();
	}

}
