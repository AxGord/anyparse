package anyparse.format.wrap;

import anyparse.core.Doc;

using StringTools;

/**
 * A list's items and per-gap separator flags after the line comments that close an item were moved past that item's
 * separator.
 */
typedef PastSepItems = {
	final items: Array<Doc>;
	final sepBeforeFlags: Null<Array<Bool>>;
}

/**
 * The one answer to "where does a line comment that closes a list element sit relative to the separator after it":
 * after the separator, so `a // c` + `,` is written `a, // c` and the separator never starts a line of its own.
 *
 * A `//` comment runs to its line end, so whatever follows it on the line belongs to the comment; the separator that
 * follows the element therefore has to come BEFORE the comment. The item keeps its comment and its line-end guard,
 * gains the separator in front of the comment, and the list's own separator at that gap is marked elided — the same
 * per-gap channel a preprocessor-absorbed separator uses, so every list shape honours it.
 */
class LineCommentPastSep {

	/**
	 * Moves the closing line comment of every item but the last past the separator that follows it. A gap whose
	 * separator the source elided keeps its item untouched (there is no separator to move past). Copy-on-write:
	 * returns the inputs themselves when no item closes on a line comment.
	 */
	public static function relocate(items: Array<Doc>, sep: String, flags: Null<Array<Bool>>): PastSepItems {
		var outItems: Null<Array<Doc>> = null;
		var outFlags: Null<Array<Bool>> = null;
		for (i in 0...items.length - 1) if (flags == null || i + 1 >= flags.length || !flags[i + 1]) {
			final moved: Null<Doc> = withSepBeforeLineComment(items[i], sep);
			if (moved == null) continue;
			if (outItems == null) {
				outItems = items.copy();
				outFlags = [for (j in 0...items.length) flags != null && j < flags.length && flags[j]];
			}
			outItems[i] = moved;
			outFlags[i + 1] = true;
		}
		return outItems == null ? { items: items, sepBeforeFlags: flags } : { items: outItems, sepBeforeFlags: outFlags };
	}

	/**
	 * Whether a list writer that owns the separator itself writes an element's trailing `comment` after that separator:
	 * one the source wrote there, and a line comment the source wrote before a separator that follows (the same move
	 * `relocate` makes for a list the wrap engine lays out).
	 */
	public static function writtenAfterSep(comment: Null<String>, beforeSep: Bool, sepFollows: Bool): Bool {
		return comment != null && (!beforeSep || sepFollows && comment.startsWith('//'));
	}

	/**
	 * The line comment a list that ends on a trail literal (`case A, B:`) writes after that literal instead of before it,
	 * or null: the one line comment that closes the list — its last element's, or the single own-line comment before the
	 * literal — when the literal's own comment slot `afterTrail` is free. Written before the literal, the comment would
	 * push the literal onto a line of its own and break the whole list around it.
	 */
	public static function movedPastTrail(lastTrailing: Null<String>, orphans: Array<String>, afterTrail: Null<String>): Null<String> {
		if (afterTrail != null) return null;
		if (lastTrailing != null) return orphans.length == 0 && lastTrailing.startsWith('//') ? lastTrailing : null;
		return orphans.length == 1 && orphans[0].startsWith('//') ? orphans[0] : null;
	}

	/**
	 * `d` with `sep` inserted before its closing line comment, or null when `d` does not close on one. The comment is
	 * found on the right spine through `Concat` only, so no group's fit decision changes: the separator lands in the
	 * same `Concat` as the comment.
	 */
	private static function withSepBeforeLineComment(d: Doc, sep: String): Null<Doc> {
		return switch d {
			case Concat(arr) if (arr.length > 0):
				final last: Int = arr.length - 1;
				if (isGuardedLineComment(arr[last])) {
					final out: Array<Doc> = arr.slice(0, last);
					out.push(Text(sep));
					out.push(arr[last]);
					Concat(out);
				} else {
					final inner: Null<Doc> = withSepBeforeLineComment(arr[last], sep);
					if (inner == null) {
						null;
					} else {
						final out: Array<Doc> = arr.copy();
						out[last] = inner;
						Concat(out);
					}
				}
			case _: null;
		};
	}

	/** A trailing line comment followed by the guard that keeps the next token off its line. */
	private static function isGuardedLineComment(d: Doc): Bool {
		return switch d {
			case Concat([Text(s, _), OptHardlineSkipBeforeHardline]): s.trim().startsWith('//');
			case _: false;
		};
	}

}
