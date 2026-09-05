package anyparse.query;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The COMMENT-ATTACHMENT half of the writer-emit gate: whether an edit set would leave a
 * comment standing above code it never documented.
 *
 * ## The clause this states
 *
 * An autofix must preserve more than "the result re-parses". Three recorded incidents say so,
 * and each names a different thing the parse gate cannot see:
 *
 *  - the STATEMENTS a brace-less construct governs (`BodySlotGuard`);
 *  - the OWNER of a documentation block (`CanonicalEdit.docSplittingEdit`);
 *  - and the one here — the CODE a comment documents.
 *
 * The motivating edit is `prefer-ternary-return`'s fix marching up a six-gate guard cascade in
 * this repo's own `MemberOrder.reorderRefusal`: each fold quoted the rung's condition and value
 * verbatim and hoisted every comment between the rungs to the front of the replacement, so two
 * per-gate explanations ended up stacked above a seven-level ternary pyramid — including the one
 * that warns against exactly that transformation. The result parses, it is byte-canonical, and
 * no lint rule reads a comment's owner, so nothing in the project objected.
 *
 * ## The positive criterion
 *
 * "Still documents the same thing" cannot be decided from text: an in-place rewrite legitimately
 * replaces the very code a comment leads, and the comment goes on documenting it. What CAN be
 * decided is whether the code that SEPARATED two comments survived.
 *
 * Group the comments into BLOCKS — maximal runs with only whitespace between them. Two blocks
 * are two blocks because code stands between them, and that code is what at least one of them
 * documents. If the edit leaves both blocks in ONE block, that code is gone from between them:
 * whatever the first block led, it does not lead it any more. That is a fact about the text, it
 * needs no model of what a comment means, and it says nothing about an edit that rewrites the
 * code under a single block.
 *
 * It is a positive criterion, not a proof of attachment, and the gap was MEASURED rather than
 * guessed. With `prefer-ternary-return`'s own cascade gate disabled and only this guard
 * standing, the T546 run goes from 10 edits over 7 passes to 7 over 4 and refuses by name — but
 * three folds have landed by then, and one comment has already been hoisted past a gate it did
 * not document. A weld is the shape a comparison of the two texts can decide on its own; "moved
 * across code that survived" is not, because an ordinary in-place rewrite changes the same
 * bytes. Deciding that one needs an edit to declare which source spans it carried verbatim,
 * which no edit currently does — backlog, not a claim this class makes.
 *
 * ## Cost
 *
 * A block merge needs code between two blocks to be REMOVED, so the pre-filter is exact and
 * free: some edit must both cover text (`span.from < span.to`) and intersect the gap between two
 * comment blocks. Only then is the spliced result lexed. Source-side regions come from the
 * caller, which already scanned them for `docSplittingEdit`.
 */
@:nullSafety(Strict)
final class CommentOwnerGuard {

	/**
	 * The refusal message for the first pair of comment blocks `edits` would weld together, or
	 * null when they weld none.
	 *
	 * `spliced` is `CanonicalEdit.applyEdits(source, edits)`, asked BEFORE the writer's
	 * fixed-point loop: the writer re-emits a comment interior byte for byte and never moves one
	 * across code, so the splice is where a move can happen and the loop only re-indents it.
	 */
	public static function detachedComment(
		source: String, edits: Array<{ span: Span, text: String }>, spliced: String, regions: Array<LexRegion>, plugin: GrammarPlugin
	): Null<String> {
		if (spliced == source || edits.length == 0) return null;
		final before: Array<Array<Span>> = blocksOf(source, SourceComments.collectCommentTokens(regions));
		if (before.length < 2 || !removesGapCode(edits, before)) return null;
		final after: Array<Array<Span>> = blocksOf(spliced, SourceComments.collectCommentTokens(plugin.lexicalRegions(spliced)));
		// Which source BLOCK each source comment belongs to, queued per comment TEXT: surviving
		// comments keep their relative order, so taking the next unused entry for a text aligns the
		// two sides without needing a diff. A text the result repeats more often than the source
		// runs the queue dry and is treated as new, which is the direction that cannot invent a
		// refusal. Keyed on the comment's FULL text, not on the excerpt the message quotes: two
		// long comments sharing a 40-character prefix would otherwise share one queue, and a
		// mis-drawn entry there is a refusal nobody could explain.
		final queue: Map<String, Array<Int>> = [];
		for (b in 0...before.length) for (span in before[b]) {
			final key: String = source.substring(span.from, span.to);
			final list: Null<Array<Int>> = queue[key];
			if (list == null)
				queue[key] = [b]
			else
				list.push(b);
		}
		final taken: Map<String, Int> = [];
		for (block in after) {
			var ownerBlock: Int = -1;
			var ownerText: String = '';
			for (span in block) {
				final key: String = spliced.substring(span.from, span.to);
				final list: Null<Array<Int>> = queue[key];
				if (list == null) continue;
				final at: Int = taken[key] ?? 0;
				if (at >= list.length) continue;
				taken[key] = at + 1;
				final b: Int = list[at];
				if (ownerBlock < 0) {
					ownerBlock = b;
					ownerText = SourceText.regionExcerpt(spliced, span);
					continue;
				}
				if (b == ownerBlock) continue;
				final welded: String = SourceText.regionExcerpt(spliced, span);
				return 'the edit would leave the comment "$ownerText" welded to "$welded" with the code that stood between them '
					+ 'gone, so at least one of the two no longer leads what it documents — keep each comment with its own statement.';
			}
		}
		return null;
	}

	/**
	 * The comment BLOCKS of `source`: maximal runs of `tokens` with only whitespace between
	 * consecutive members, in source order. A trailing comment and the own-line comment on the
	 * next line form one block, which is the conservative grouping — it can only merge blocks the
	 * criterion would otherwise have compared, never split one.
	 */
	private static function blocksOf(source: String, tokens: Array<{ from: Int, to: Int, isLine: Bool }>): Array<Array<Span>> {
		final blocks: Array<Array<Span>> = [];
		var current: Array<Span> = [];
		var previous: Int = -1;
		for (token in tokens) {
			if (previous >= 0 && source.substring(previous, token.from).trim() != '') {
				blocks.push(current);
				current = [];
			}
			current.push(new Span(token.from, token.to));
			previous = token.to;
		}
		if (current.length > 0) blocks.push(current);
		return blocks;
	}

	/**
	 * Whether any edit COVERS text inside the gap between two consecutive comment blocks — the
	 * exact precondition for a merge, since two blocks can only become one when the code between
	 * them stops being there. A pure insertion adds text and can never do it.
	 */
	private static function removesGapCode(edits: Array<{ span: Span, text: String }>, blocks: Array<Array<Span>>): Bool {
		for (k in 0...blocks.length - 1) {
			final from: Int = blocks[k][blocks[k].length - 1].to;
			final to: Int = blocks[k + 1][0].from;
			if (edits.exists(edit -> edit.span.from < edit.span.to && edit.span.from < to && edit.span.to > from)) return true;
		}
		return false;
	}

}
