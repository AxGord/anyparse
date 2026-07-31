package anyparse.format.comment;

import haxe.Exception;

/**
 * Thrown by a writer round trip whose output would drop a comment the
 * source carried (see `CommentInventory`). Deleting an author's comment
 * is data loss, so the round trip refuses instead of handing back the
 * lossy bytes: `apq fmt` reports the file and leaves it untouched, and
 * every op that canonicalises through `RefactorSupport` refuses its edit
 * rather than writing a file without the comment.
 *
 * Its own type (rather than a bare `Exception`) so those callers can tell
 * a refusal from a parse failure and say so in their message.
 *
 * The message states only the FACT — the remedy differs per seat (a file
 * left unchanged, an edit refused, a create rejected), so each caller adds
 * its own around `comment`.
 */
@:nullSafety(Strict)
final class CommentLossException extends Exception {

	/** The first comment of the source that the writer output did not carry. */
	public final comment: String;

	public function new(comment: String) {
		super('the writer round trip would drop the comment `$comment`');
		this.comment = comment;
	}

}
