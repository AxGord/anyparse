package anyparse.format.comment;

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
 * The scan skips string and regex literals so a `"/* not a comment *\/"`
 * payload never counts as a comment on either side, and it follows a
 * single-quoted string's `${…}` interpolation as CODE — a nested same-quote
 * literal there would otherwise desynchronise the scan for the rest of the
 * file, which is the one way a real loss could hide from this check.
 */
@:nullSafety(Strict)
final class CommentInventory {

	/** Longest comment head an error message quotes before eliding. */
	private static inline final MESSAGE_WIDTH: Int = 60;

	/** The quote that opens an INTERPOLATING string literal in Haxe. */
	private static inline final SINGLE_QUOTE: Int = "'".code;

	private function new() {}

	/**
	 * The first comment of `source` that `output` does not carry, verbatim
	 * and truncated to one line for a message; `null` when every comment
	 * survived. Comment bodies are compared ignoring the whitespace-level
	 * reformatting the writer is allowed to perform.
	 */
	public static function firstMissing(source: String, output: String): Null<String> {
		final wanted: Array<String> = collect(source);
		if (wanted.length == 0) return null;
		final have: Map<String, Int> = [];
		for (c in collect(output)) {
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

	/** One-line rendering of a comment for an error message. */
	private static function summarize(comment: String): String {
		final firstLine: Int = comment.indexOf('\n');
		final head: String = firstLine < 0 ? comment : comment.substring(0, firstLine) + ' ...';
		return head.length > MESSAGE_WIDTH ? head.substr(0, MESSAGE_WIDTH) + ' ...' : head;
	}

	/**
	 * Every `//` and `/* *\/` comment in `src`, verbatim and in source
	 * order, with string and regex literals skipped.
	 *
	 * A single-quoted string's `${…}` interpolation is scanned as CODE, so a
	 * nested same-quote literal (`'a ${f(\'b\')} c'`) cannot desynchronise the
	 * scan — and a comment written inside the interpolation is counted like
	 * any other. `$$` is the escaped dollar and opens nothing.
	 */
	public static function collect(src: String): Array<String> {
		final out: Array<String> = [];
		final len: Int = src.length;
		// One entry per open `${` interpolation, holding the `{` nesting depth
		// reached inside it; the frame closes on the `}` that meets depth 0.
		final interpolations: Array<Int> = [];
		// The open quote character while inside a string literal, 0 in code.
		var quote: Int = 0;
		var i: Int = 0;
		while (i < len) {
			final c: Int = StringTools.fastCodeAt(src, i);
			final next: Int = i + 1 < len ? StringTools.fastCodeAt(src, i + 1) : 0;
			if (quote != 0) {
				if (c == '\\'.code) {
					i += 2;
					continue;
				}
				if (quote == SINGLE_QUOTE && c == '$'.code && next == '$'.code) {
					i += 2;
					continue;
				}
				if (quote == SINGLE_QUOTE && c == '$'.code && next == '{'.code) {
					interpolations.push(0);
					quote = 0;
					i += 2;
					continue;
				}
				if (c == quote) quote = 0;
				i++;
				continue;
			}
			if (c == '/'.code && next == '/'.code) {
				final start: Int = i;
				while (i < len && StringTools.fastCodeAt(src, i) != '\n'.code) i++;
				out.push(src.substring(start, i));
				continue;
			}
			if (c == '/'.code && next == '*'.code) {
				final start: Int = i;
				final close: Int = src.indexOf('*/', i + 2);
				i = close < 0 ? len : close + 2;
				out.push(src.substring(start, i));
				continue;
			}
			if (c == '"'.code || c == SINGLE_QUOTE) {
				quote = c;
				i++;
				continue;
			}
			// `~/` opens a regex literal; it runs to an unescaped `/` on the
			// same line (an unterminated one is a syntax error the parser
			// would have rejected long before the writer ran).
			if (c == '~'.code && next == '/'.code) {
				i = skipRegex(src, i + 2);
				continue;
			}
			if (interpolations.length > 0 && (c == '{'.code || c == '}'.code)) {
				final last: Int = interpolations.length - 1;
				if (c == '{'.code)
					interpolations[last] = interpolations[last] + 1;
				else if (interpolations[last] == 0) {
					interpolations.pop();
					quote = SINGLE_QUOTE;
				} else
					interpolations[last] = interpolations[last] - 1;
				i++;
				continue;
			}
			i++;
		}
		return out;
	}

	private static function skipRegex(src: String, from: Int): Int {
		final len: Int = src.length;
		var i: Int = from;
		while (i < len) {
			final c: Int = StringTools.fastCodeAt(src, i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			i++;
			if (c == '/'.code || c == '\n'.code) break;
		}
		return i;
	}

	/**
	 * Comment text stripped to what the writer may NOT change: delimiters,
	 * the per-line `*` gutter and all whitespace removed.
	 */
	private static function normalize(comment: String): String {
		final buf: StringBuf = new StringBuf();
		final len: Int = comment.length;
		var i: Int = 0;
		var atLineStart: Bool = true;
		if (StringTools.startsWith(comment, '//'))
			i = 2;
		else if (StringTools.startsWith(comment, '/*')) {
			i = 2;
			// A trailing `*/` (and the `*` of a `**/` close) carries no text.
			var end: Int = len;
			if (StringTools.endsWith(comment, '*/')) end -= 2;
			while (end > i && StringTools.fastCodeAt(comment, end - 1) == '*'.code) end--;
			return normalizeBody(comment.substring(i, end));
		}
		while (i < len) {
			final c: Int = StringTools.fastCodeAt(comment, i);
			i++;
			if (c == ' '.code || c == '\t'.code || c == '\r'.code || c == '\n'.code) continue;
			if (atLineStart && c == '*'.code) continue;
			atLineStart = false;
			buf.addChar(c);
		}
		return buf.toString();
	}

	private static function normalizeBody(body: String): String {
		final buf: StringBuf = new StringBuf();
		final len: Int = body.length;
		var i: Int = 0;
		var atLineStart: Bool = true;
		while (i < len) {
			final c: Int = StringTools.fastCodeAt(body, i);
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
