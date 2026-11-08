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

}
