package anyparse.query;

import anyparse.query.CanonicalEdit.CarriedEdit;
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
 * guessed. With `prefer-ternary-return`'s own cascade gate disabled and only this criterion
 * standing, the T546 cascade lands three folds and hoists one comment past a gate it does not
 * document before the weld is reached (measured S86, on the reduced fixture: 3 edits over 4
 * passes).
 *
 * ## The second criterion, and why it needs the caller
 *
 * A weld is the shape a comparison of the two texts can decide on its own; "moved across code
 * that survived" is not, because an ordinary in-place rewrite changes the same bytes. S86 closed
 * that half by giving edits a way to SAY what they quote verbatim (`CanonicalEdit.CarriedEdit`,
 * `Check.CarryingFix`) and asking `hoistedComment` below. It is opt-in by construction: an edit
 * set that declares nothing is judged exactly as it was, and the same cascade with the
 * declaration in place stops after ONE fold with no comment detached.
 *
 * ## Cost
 *
 * A block merge needs code between two blocks to be REMOVED, so the pre-filter is exact and
 * free: some edit must both cover text (`span.from < span.to`) and intersect the gap between two
 * comment blocks. Only then is the spliced result lexed. Source-side regions come
 * from the caller, which already scanned them for `docSplittingEdit`. The carry criterion is
 * cheaper still: it reads one edit's own span and text, so it needs neither the splice nor a lex,
 * and an undeclared edit set pays one length test.
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
	 * The refusal for the first DECLARED edit whose replacement moves a comment across source
	 * code the same edit quotes VERBATIM, or null when none does — the half of the clause
	 * `detachedComment` says above it cannot decide.
	 *
	 * `detachedComment` asks about the whole edit SET and needs no cooperation: two comment
	 * blocks welded into one is a fact about two texts. This asks about ONE edit and cannot be
	 * derived, because an in-place rewrite and a hoist change the same bytes. What makes it
	 * decidable is the `CarriedEdit` declaration: the edit NAMES the source ranges its
	 * replacement quotes verbatim, so "the code survived" stops being a guess. A comment that
	 * stood before one of those ranges in the source and stands after it in the replacement
	 * crossed it, and no longer leads what it documented.
	 *
	 * Everything it reads lives inside the one edit — that edit's span, its replacement text, and
	 * the source comment tokens the caller already scanned — so it needs neither the splice nor a
	 * lex of the result, and an edit set that declares nothing costs one length test.
	 *
	 * FAIL-OPEN on a declaration that does not hold: a fragment the replacement does not contain,
	 * a comment text the replacement repeats, an empty declaration. That is the only direction
	 * that cannot invent a refusal out of a producer's bookkeeping mistake, and a producer that
	 * under-declares gets exactly the weaker guarantee it asked for.
	 */
	public static function hoistedComment(
		source: String, edits: Array<{ span: Span, text: String }>, carried: Array<CarriedEdit>, regions: Array<LexRegion>
	): Null<String> {
		if (carried.length == 0) return null;
		final tokens: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(regions);
		if (tokens.length == 0) return null;
		for (entry in carried) if (entry.spans.length != 0) {
			final edit: Null<{ span: Span, text: String }> = edits.find(candidate ->
				candidate.span.from == entry.edit.from && candidate.span.to == entry.edit.to
			);
			if (edit == null) continue;
			final hits: Array<PlacedComment> = placeableComments(source, edit.text, tokens, entry);
			if (hits.length == 0) continue;
			final placed: Null<Array<Span>> = placedCarry(source, entry.spans, edit.text);
			if (placed == null) continue;
			for (hit in hits) {
				final moved: Null<{ code: Span, hoisted: Bool }> = crossedCarry(entry.spans, placed, hit);
				if (moved == null) continue;
				final comment: String = SourceText.regionExcerpt(source, new Span(hit.token.from, hit.token.to));
				return 'the edit would move the comment "$comment" ${moved.hoisted ? 'above' : 'below'} '
					+ '"${SourceText.regionExcerpt(source, moved.code)}", which the same edit carries verbatim, so the comment '
					+ 'no longer leads what it documented — keep it beside the code it explains.';
			}
		}
		return null;
	}

	/**
	 * The comments of `source` that stand inside this edit's region, are not part of what it
	 * carries, and can be LOCATED in its replacement — each paired with where it landed there.
	 *
	 * A comment the replacement DROPS is not this guard's business (the writer's own
	 * `CommentLossException` owns that), and one it repeats cannot be placed at all. Both are left
	 * out, which is the same fail-open direction the rest of the criterion takes.
	 */
	private static function placeableComments(
		source: String, text: String, tokens: Array<CommentToken>, entry: CarriedEdit
	): Array<PlacedComment> {
		final out: Array<PlacedComment> = [];
		for (token in tokens) {
			if (token.from < entry.edit.from || token.to > entry.edit.to) continue;
			if (entry.spans.exists(span -> token.from >= span.from && token.to <= span.to)) continue;
			final quoted: String = source.substring(token.from, token.to);
			final at: Int = text.indexOf(quoted);
			if (at >= 0 && at == text.lastIndexOf(quoted)) out.push({ token: token, at: at });
		}
		return out;
	}

	/**
	 * The carried code `hit` changed sides with, plus which way the comment went — or null when it
	 * kept its place relative to every one of them.
	 *
	 * Quoted as ONE range spanning every carry that flipped rather than as the first of them: a
	 * condition or a returned value can be a single character, and `above "a"` names nothing a
	 * reader can find in the file.
	 */
	private static function crossedCarry(spans: Array<Span>, placed: Array<Span>, hit: PlacedComment): Null<{
		code: Span,
		hoisted: Bool
	}> {
		var code: Null<Span> = null;
		var hoisted: Bool = false;
		for (k in 0...spans.length) {
			final codeFirstInSource: Bool = spans[k].to <= hit.token.from;
			if (codeFirstInSource == (placed[k].to <= hit.at)) continue;
			final was: Null<Span> = code;
			if (was == null) {
				code = spans[k];
				hoisted = codeFirstInSource;
			} else
				code = new Span(was.from < spans[k].from ? was.from : spans[k].from, was.to > spans[k].to ? was.to : spans[k].to);
		}
		final crossed: Null<Span> = code;
		return crossed == null ? null : { code: crossed, hoisted: hoisted };
	}

	/**
	 * Where each declared carry lands inside `code`, or null when the declaration does not hold.
	 * Scanned left to right in the DECLARED order, which is the order the fragments appear in the
	 * replacement, so a fragment the replacement repeats resolves to the occurrence following the
	 * previous one rather than to the first in the text.
	 *
	 * A short fragment (`a`, `1`) can match inside a COMMENT the replacement carries rather than at
	 * the code the producer meant, and that cannot change a verdict: a placement inside a comment
	 * ends after that comment starts, so the fragment reads as "not before it" — which is what it
	 * would have read anyway had the comment moved above it. An earlier revision blanked every
	 * comment out of `code` first; arm F5 (that blanking made a no-op) left all 13 980 tests green
	 * AND every refusal message byte-identical, so it was work with no verdict attached and went.
	 */
	private static function placedCarry(source: String, spans: Array<Span>, code: String): Null<Array<Span>> {
		final placed: Array<Span> = [];
		var at: Int = 0;
		for (span in spans) {
			final fragment: String = source.substring(span.from, span.to);
			if (fragment.length == 0) return null;
			final found: Int = code.indexOf(fragment, at);
			if (found < 0) return null;
			placed.push(new Span(found, found + fragment.length));
			at = found + fragment.length;
		}
		return placed;
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

/**
 * One comment token as `SourceComments.collectCommentTokens` yields it: its span, and whether it
 * is a `//` line comment rather than a `/* … *\/` block. Named here because the carry criterion
 * threads it through three signatures and the structural spelling drowned them.
 */
typedef CommentToken = {
	final from: Int;
	final to: Int;
	final isLine: Bool;
}

/** One `CommentToken` of the source together with the offset it landed at inside a replacement. */
typedef PlacedComment = {
	final token: CommentToken;
	final at: Int;
}
