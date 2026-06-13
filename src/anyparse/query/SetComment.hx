package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Replace the comment at a cursor — the comment counterpart of `set-doc`
 * (which is declaration-doc-only and block-comment-only). Inline line
 * comments are trivia, not AST nodes, so no other op can reach them; this
 * fills that gap so every edit to a parseable `.hx` stays inside the op set.
 *
 * The comment at the cursor is resolved by `RefactorSupport.commentBlockAt`:
 * a block comment is replaced whole; a full-line line comment is replaced
 * together with the contiguous run of full-line line comments around it (a
 * line-comment block edited as one unit); a trailing line comment after code
 * is replaced alone. The replacement must itself be a comment (its trimmed
 * text begins with a line- or block-comment opener); it is spliced verbatim
 * and the whole file is re-emitted + re-parse-validated via
 * `RefactorSupport.canonicalize` (canonical-gated unless `reformat`), so the
 * writer re-indents the new comment to its attachment context.
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class SetComment {

	/**
	 * Replace the comment at `line:col` (the `apq refs` column convention)
	 * with `commentText`. Returns `Ok(rewritten)` or an `Err` describing why
	 * the comment could not be set.
	 */
	public static function setComment(
		source: String, line: Int, col: Int, commentText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		try
			plugin.parseFile(source)
		catch (exception: ParseError)
			return Err('source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('source does not parse: ${exception.message}');

		final trimmed: String = StringTools.trim(commentText);
		if (trimmed.length == 0) return Err('set-comment requires a non-empty comment text');
		if (!StringTools.startsWith(trimmed, '//') && !StringTools.startsWith(trimmed, '/*'))
			return Err('set-comment replacement must be a comment (start with // or /*)');

		final cursor: Int = Span.offsetOf(source, line, col);
		final span: Null<Span> = RefactorSupport.commentBlockAt(source, cursor);
		if (span == null) return Err('position $line:$col is not on a comment');

		final edit: { span: Span, text: String } = { span: span, text: trimmed };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

}
