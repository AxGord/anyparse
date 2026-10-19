package anyparse.format.comment;

using Lambda;
using StringTools;

/**
 * Whether a comment is a DIRECTIVE — text another tool reads off the line it sits on — rather than prose a
 * layout pass may move or re-wrap.
 *
 * Four spellings are directives: a lint suppression (`noqa`, `noqa: rule`, read by `check.Suppression` against
 * the line the comment is ON), a `CHECKSTYLE:OFF` / `CHECKSTYLE:ON` region marker, a `@formatter:off` /
 * `@formatter:on` region marker (`FormatterOff`), and an IDE's `#region` / `#endregion` fold marker. The one list
 * every reader shares: `check.CommentProse` (gate 5 of `prefer-doc-comment`), the comment reflow
 * (`SourceComments.reflowRefusal`) and the writer's trailing-comment move. Moving the first to another line silences a different line, or
 * none; breaking `noqa: some-rule` after the colon turns one exemption into a blanket one; moving either marker
 * shifts the region it opens or closes.
 *
 * The test runs on the comment's TEXT with its delimiters stripped and is a prefix match, case-insensitive, so it
 * refuses more than the readers accept (`noqa-ish`, `checkstyle:anything`) and never less: every consumer is a
 * pass that may decline, and declining a prose comment that happens to start like a directive costs one line left
 * where it was.
 */
@:nullSafety(Strict)
final class CommentDirective {

	private static final DIRECTIVE_PREFIXES: Array<String> = ['noqa', 'checkstyle:', '@formatter:', '#region', '#endregion'];

	/** True when `text` (a comment body, delimiters stripped) is a directive by the rule above. */
	public static function isDirective(text: String): Bool {
		final lower: String = text.trim().toLowerCase();
		return DIRECTIVE_PREFIXES.exists(prefix -> lower.startsWith(prefix));
	}

	/**
	 * True when `comment` — a captured trailing comment WITH its delimiters — may move to its own line above the
	 * code it trails: a `//` line comment that is not a directive. A block comment is refused whatever it says: it
	 * is not a line comment in the source the author wrote, and a reader of `/* … *\/` in that slot has no shape to
	 * compare against.
	 */
	public static function relocatableTrailing(comment: String): Bool {
		return comment.startsWith('//') && !isDirective(comment.substring(2));
	}

}
