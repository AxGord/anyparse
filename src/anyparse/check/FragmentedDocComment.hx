package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * A comment token from `RefactorSupport.collectCommentTokens`.
 */
typedef CommentTok = { from: Int, to: Int, isLine: Bool };

/**
 * Flags a declaration's doc that is split across SEVERAL adjacent block comments
 * (each separately opened and closed) instead of one — a common artifact of a doc
 * edit that inserted a second block rather than replacing the first, which reads as
 * a confusing duplicate. `Severity.Info`; `--fix` merges the run into a single
 * doc comment, concatenating the block bodies.
 *
 * ## Detection
 *
 * Purely a comment-token scan (comments are dropped from the query projection):
 * two or more block comments separated by ONLY whitespace with no blank line
 * (consecutive lines) form a fragmented run. A blank line between blocks, a line
 * comment, or any code breaks the run — those are treated as deliberately separate.
 * Behaviour-safe: comments never affect compilation, and the merged body keeps every
 * block's text.
 */
@:nullSafety(Strict)
final class FragmentedDocComment implements Check {

	public function new() {}

	public function id(): String {
		return 'fragmented-doc-comment';
	}

	public function description(): String {
		return 'a declaration documented by several adjacent comment blocks instead of one';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) for (run in adjacentBlockRuns(entry.source)) violations.push({
			file: entry.file,
			span: new Span(run[0].from, run[run.length - 1].to),
			rule: 'fragmented-doc-comment',
			severity: Severity.Info,
			message: 'this declaration is documented by ${run.length} adjacent comment blocks; merge them into one'
		});
		return violations;
	}

	/** Merge each flagged run of adjacent block comments into a single doc comment. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (run in adjacentBlockRuns(source)) if (flagged.contains(run[0].from)) {
			final bodies: Array<String> = run.map(cleanBlockBody.bind(source));
			edits.push({ span: new Span(run[0].from, run[run.length - 1].to), text: RefactorSupport.docComment(bodies.join('\n')) });
		}
		return edits;
	}

	/** Runs of 2+ block comments on consecutive lines (whitespace-only, no blank line, between them). */
	private static function adjacentBlockRuns(source: String): Array<Array<CommentTok>> {
		final comments: Array<CommentTok> = RefactorSupport.collectCommentTokens(source);
		final runs: Array<Array<CommentTok>> = [];
		var i: Int = 0;
		while (i < comments.length) {
			if (isDocBlock(source, comments[i])) {
				var j: Int = i;
				while (j + 1 < comments.length && isDocBlock(source, comments[j + 1]) && tightlyAdjacent(
					source, comments[j], comments[j + 1]
				))
					j++;
				if (j > i) runs.push(comments.slice(i, j + 1));
				i = j + 1;
			} else
				i++;
		}
		return runs;
	}

	/**
	 * Whether `tok` is a documentation block — opens with the doc marker and is not
	 * the empty form. A plain block comment (a license header, a section banner) is
	 * NOT a doc and so never joins a fragmented-doc run, matching the doc-vs-plain
	 * discrimination `RefactorSupport.docExtendedSpan` already makes.
	 */
	private static function isDocBlock(source: String, tok: CommentTok): Bool {
		return !tok.isLine && tok.to - tok.from > 4 && source.substring(tok.from, tok.from + 3) == '/**';
	}

	/** Whether only whitespace with at most one newline separates `a` and `b` (consecutive lines, no blank line). */
	private static function tightlyAdjacent(source: String, a: CommentTok, b: CommentTok): Bool {
		final gap: String = source.substring(a.to, b.from);
		if (StringTools.trim(gap) != '') return false;
		var newlines: Int = 0;
		for (k in 0...gap.length) if (StringTools.fastCodeAt(gap, k) == '\n'.code) newlines++;
		return newlines <= 1;
	}

	/** The text of a block comment's body — the delimiters and each line's leading marker stripped, blank edge lines trimmed. */
	private static function cleanBlockBody(source: String, tok: CommentTok): String {
		final body: Span = RefactorSupport.commentBody(source, tok);
		final lines: Array<String> = source.substring(body.from, body.to).split('\n').map(stripMarker);
		while (lines.length > 0 && StringTools.trim(lines[0]) == '') lines.shift();
		while (lines.length > 0 && StringTools.trim(lines[lines.length - 1]) == '') lines.pop();
		return lines.join('\n');
	}

	/** Strip a line's leading whitespace and a single leading doc marker, plus trailing whitespace. */
	private static function stripMarker(line: String): String {
		var s: String = StringTools.ltrim(line);
		if (StringTools.startsWith(s, '* '))
			s = s.substr(2);
		else if (s == '*')
			s = '';
		else if (StringTools.startsWith(s, '*'))
			s = s.substr(1);
		return StringTools.rtrim(s);
	}

}
