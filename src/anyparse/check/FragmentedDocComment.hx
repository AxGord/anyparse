package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

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

	/**
	 * The fragment that precedes the BLOCK TALLY in a message. Spelled once, but NOT used as a
	 * `Check.VolatileMessage` mask anchor, and the reason is the criterion that interface
	 * states: keep a number that is the last DISCRIMINATOR between two neighbouring findings.
	 * This message carries no name and no position — the tally is not merely the last
	 * discriminator it has, it is the ONLY one — so masking it collapsed every finding of this
	 * rule in one file onto a single key and made a substitution between two fragmented
	 * declarations invisible to `apq lint-diff`. S15 masked it, a review caught it, and it was
	 * reverted here rather than in the consumer.
	 */
	private static inline final BLOCK_COUNT_LEAD: String = 'documented by ';

	public function new() {}

	public function id(): String {
		return 'fragmented-doc-comment';
	}

	public function description(): String {
		return 'a declaration documented by several adjacent comment blocks instead of one';
	}


	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) for (run in adjacentBlockRuns(entry.source, plugin.lexicalRegions(entry.source)))
				{
					file: entry.file,
					span: new Span(run[0].from, run[run.length - 1].to),
					rule: 'fragmented-doc-comment',
					severity: Severity.Info,
					message: 'this declaration is $BLOCK_COUNT_LEAD${run.length} adjacent comment blocks; merge them into one'
				}
		];
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
		for (run in adjacentBlockRuns(source, plugin.lexicalRegions(source))) if (flagged.contains(run[0].from)) {
			final bodies: Array<String> = run.map(cleanBlockBody.bind(source));
			edits.push({ span: new Span(run[0].from, run[run.length - 1].to), text: SourceComments.docComment(bodies.join('\n')) });
		}
		return edits;
	}

	/**
	 * Whether `tok` is a documentation block — opens with the doc marker and is not
	 * the empty form. A plain block comment (a license header, a section banner) is
	 * NOT a doc and so never joins a fragmented-doc run, matching the doc-vs-plain
	 * discrimination `RefactorSupport.docExtendedSpan` already makes.
	 */
	private static inline function isDocBlock(source: String, tok: CommentTok): Bool {
		return SourceComments.isDocBlock(source, tok);
	}

	/** Runs of 2+ block comments on consecutive lines (whitespace-only, no blank line, between them). */
	private static function adjacentBlockRuns(source: String, regions: Array<LexRegion>): Array<Array<CommentTok>> {
		final comments: Array<CommentTok> = SourceComments.collectCommentTokens(regions);
		final runs: Array<Array<CommentTok>> = [];
		var i: Int = 0;
		while (i < comments.length) {
			if (isDocBlock(source, comments[i])) {
				var j: Int = i;
				while (
					j + 1 < comments.length && isDocBlock(source, comments[j + 1]) && tightlyAdjacent(source, comments[j], comments[j + 1])
				)
					j++;
				if (j > i) runs.push(comments.slice(i, j + 1));
				i = j + 1;
			} else
				i++;
		}
		return runs;
	}

	/** Whether only whitespace with at most one newline separates `a` and `b` (consecutive lines, no blank line). */
	private static function tightlyAdjacent(source: String, a: CommentTok, b: CommentTok): Bool {
		final gap: String = source.substring(a.to, b.from);
		if (gap.trim() != '') return false;
		var newlines: Int = 0;
		for (k in 0...gap.length) if (gap.fastCodeAt(k) == '\n'.code) newlines++;
		return newlines <= 1;
	}

	/** The text of a block comment's body — the delimiters and each line's leading marker stripped, blank edge lines trimmed. */
	private static function cleanBlockBody(source: String, tok: CommentTok): String {
		final body: Span = SourceComments.commentBody(source, tok);
		return SourceComments.trimBlankEdges(source.substring(body.from, body.to).split('\n').map(stripMarker)).join('\n');
	}

	/** Strip a line's leading whitespace and a single leading doc marker, plus trailing whitespace. */
	private static function stripMarker(line: String): String {
		var s: String = line.ltrim();
		if (s.startsWith('* '))
			s = s.substr(2);
		else if (s == '*')
			s = '';
		else if (s.startsWith('*'))
			s = s.substr(1);
		return s.rtrim();
	}

}
