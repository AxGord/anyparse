package anyparse.runtime;

using StringTools;

/**
 * The one answer to "how a run of comments is written into one trailing-comment slot": block comments share a line,
 * separated by a space, and a line comment ends its line, so whatever follows it starts the next.
 */
@:nullSafety(Strict)
final class CommentRun {

	/** `comments` joined into one slot value, in source order. */
	public static function join(comments: Array<String>): String {
		var out: Null<String> = null;
		var prevLine: Bool = false;
		for (c in comments) {
			out = out == null ? c : out + (prevLine ? '\n' : ' ') + c;
			prevLine = c.startsWith('//');
		}
		return out ?? '';
	}

	/** `slot` cut back into the lines `join` wrote it on: a newline outside a block comment ends one. */
	public static function lines(slot: String): Array<String> {
		final out: Array<String> = [];
		var start: Int = 0;
		var i: Int = 0;
		while (i < slot.length) {
			if (opensAt(slot, i, '*'.code)) {
				final close: Int = slot.indexOf('*/', i + 2);
				i = close < 0 ? slot.length : close + 2;
			} else if (opensAt(slot, i, '/'.code)) {
				final eol: Int = slot.indexOf('\n', i);
				i = eol < 0 ? slot.length : eol;
			} else {
				if (slot.fastCodeAt(i) == '\n'.code) {
					out.push(slot.substring(start, i));
					start = i + 1;
				}
				i++;
			}
		}
		out.push(slot.substring(start));
		return out;
	}

	/** Whether the run ends in a line comment, which runs to the end of its line, so no token may follow it there. */
	public static function endsWithLineComment(slot: String): Bool {
		final run: Array<String> = lines(slot);
		final last: String = run[run.length - 1];
		var i: Int = 0;
		while (i < last.length) {
			if (opensAt(last, i, '/'.code)) return true;
			if (opensAt(last, i, '*'.code)) {
				final close: Int = last.indexOf('*/', i + 2);
				i = close < 0 ? last.length : close + 2;
			} else {
				i++;
			}
		}
		return false;
	}

	/** Whether a comment whose second character is `second` (`*` block, `/` line) opens at `i` of `s`. */
	private static inline function opensAt(s: String, i: Int, second: Int): Bool {
		return i + 1 < s.length && s.fastCodeAt(i) == '/'.code && s.fastCodeAt(i + 1) == second;
	}

}
