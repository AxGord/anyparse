package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a content-free comment — a line comment with only whitespace after the
 * slashes, an empty block comment, or an empty doc comment (including a multi-line
 * one whose interior is only stars and whitespace). Deliberate divider runs (dashed
 * rules), directive comments (noqa), and any printable content are kept;
 * conditional-compilation lines are not comments and never match. `Warning`.
 *
 * ## Detection
 *
 * A pure comment-token scan (no parse needed) over `RefactorSupport.collectCommentTokens`,
 * which is string-aware — a slash-slash inside a STRING literal is never visited. A
 * line comment is empty when every unit after the slashes is whitespace; a block or
 * doc comment when it is closed and its interior between the delimiters is only
 * whitespace and stars.
 *
 * ## Fix
 *
 * `fix` deletes each flagged comment. A comment alone on its line(s) takes the whole
 * physical line(s) with it (no blank residue); a comment trailing code is stripped and
 * the code line rtrimmed; a comment with code after it on the same line is removed on
 * its own. The edits are the raw deletions the caller batches into one
 * `RefactorSupport.canonicalize` per file.
 */
@:nullSafety(Strict)
final class EmptyComment implements Check {

	public function new() {}

	public function id(): String {
		return 'empty-comment';
	}

	public function description(): String {
		return 'an empty comment (a content-free // or /* */)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) scan(violations, entry.file, entry.source);
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: deletionSpan(source, span), text: '' });
		}
		return edits;
	}

	/** Scan every comment token in `source`, flagging each content-free one. */
	private static function scan(out: Array<Violation>, file: String, source: String): Void {
		for (tok in RefactorSupport.collectCommentTokens(source)) if (isEmpty(source, tok)) out.push({
			file: file,
			span: new Span(tok.from, tok.to),
			rule: 'empty-comment',
			severity: Severity.Warning,
			message: 'empty comment'
		});
	}

	/**
	 * Whether the comment token is content-free: a line comment with only whitespace
	 * after the slashes, or a closed block/doc comment whose interior between the
	 * delimiters is only whitespace and stars (doc gutters). An unclosed block comment
	 * is never treated as empty.
	 */
	private static function isEmpty(source: String, tok: { from: Int, to: Int, isLine: Bool }): Bool {
		if (!tok.isLine) return RefactorSupport.blockCommentIsBlank(source, tok);
		for (i in tok.from + 2...tok.to) if (!isWs(StringTools.fastCodeAt(source, i))) return false;
		return true;
	}

	/**
	 * The span to delete for the empty comment at `span`. Alone on its line(s) (only
	 * whitespace around it) → the whole physical line(s), so the batched re-emit leaves
	 * no blank residue; trailing code with only whitespace after → the comment plus the
	 * whitespace before it (rtrimming the code line); code after it on the same line →
	 * only the comment itself.
	 */
	private static function deletionSpan(source: String, span: Span): Span {
		var lineStart: Int = span.from;
		while (lineStart > 0 && StringTools.fastCodeAt(source, lineStart - 1) != '\n'.code) lineStart--;
		var lineEnd: Int = span.to;
		while (lineEnd < source.length && StringTools.fastCodeAt(source, lineEnd) != '\n'.code) lineEnd++;
		final codeBefore: Bool = StringTools.trim(source.substring(lineStart, span.from)) != '';
		final codeAfter: Bool = StringTools.trim(source.substring(span.to, lineEnd)) != '';
		if (!codeBefore && !codeAfter) return RefactorSupport.lineExtendedSpan(source, span);
		if (codeAfter) return span;
		var from: Int = span.from;
		while (from > lineStart) {
			final c: Int = StringTools.fastCodeAt(source, from - 1);
			if (c == ' '.code || c == '\t'.code)
				from--
			else
				break;
		}
		return new Span(from, span.to);
	}

	/** Whether code unit `c` is horizontal or vertical whitespace. */
	private static inline function isWs(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}
