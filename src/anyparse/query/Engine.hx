package anyparse.query;

import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.Selector.SelectorSegment;
import anyparse.runtime.Span;

/**
 * Generic tree-walker operations used by every `apq` subcommand.
 *
 * Strictly language-agnostic — every function operates on `QueryNode`
 * and `Selector` without any knowledge of which grammar produced the
 * tree.
 */
@:nullSafety(Strict)
final class Engine {

	/**
	 * Truncate `node` to `maxDepth`. Returns a copy where every node
	 * at depth `maxDepth` has its `children` cleared. `maxDepth < 0`
	 * is a no-op (returns the original tree).
	 *
	 * Depth `0` is the root; depth `1` is its direct children; etc.
	 */
	public static function truncate(node: QueryNode, maxDepth: Int): QueryNode {
		return maxDepth < 0 ? node : truncateAt(node, 0, maxDepth);
	}

	/**
	 * Cap direct-child count to `maxChildren` at every level. Returns a
	 * copy where every node with more than `maxChildren` direct children
	 * has the overflow replaced by a single sentinel `(... N more)` leaf.
	 * `maxChildren < 0` is a no-op.
	 *
	 * Compose with `truncate` for "show first N children up to depth M"
	 * — useful on long member lists / array literals where depth alone
	 * doesn't compress the horizontal width.
	 */
	public static function truncateChildren(node: QueryNode, maxChildren: Int): QueryNode {
		return maxChildren < 0 ? node : truncateChildrenAt(node, maxChildren);
	}

	/**
	 * Walk `tree` and return every node that matches `selector`.
	 * Combinators in `selector` walk left-to-right; only direct-child
	 * relationships are tested per the v1 selector spec.
	 *
	 * `equiv` (when supplied) is the grammar's kind-equivalence relation,
	 * threaded into each segment's kind test so `--select ClassDecl` also
	 * matches a `final class`'s `ClassForm` (and `FnMember` a `final`
	 * method's `FinalModifiedMember`). Omitting it keeps the exact-kind
	 * behaviour — the matcher stays language-agnostic by default.
	 */
	public static function select(tree: QueryNode, selector: Selector, ?equiv: KindEquivalence): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		walkSelect(tree, selector, 0, out, equiv);
		return out;
	}

	/**
	 * Innermost node whose span contains `offset` (0-indexed,
	 * start-inclusive / end-exclusive — `from <= offset < to`).
	 * Returns null when no spanned node covers the offset (e.g. it
	 * falls in inter-token whitespace, or past end of source). The
	 * synthetic root carries no span, so it never wins; its spanned
	 * children are still searched.
	 */
	public static function at(tree: QueryNode, offset: Int): Null<QueryNode> {
		// -1 is an inert placeholder: `atWalk` only compares the width
		// when a best already exists (`curBest == null ||` short-circuits
		// first), so the seed value never participates in the decision.
		return atWalk(tree, offset, null, -1).node;
	}

	/**
	 * Innermost node of kind `kind` whose span contains `offset` — `at`
	 * narrowed by a kind filter. This disambiguates co-starting nodes that
	 * plain `at` cannot reach: an operator / wrapper node shares its
	 * `span.from` with its first child, so `at` (innermost overall) always
	 * picks the child; `atKind(_, _, 'Add')` instead picks the `Add` itself.
	 * Among nested same-kind nodes the smallest containing one wins, so
	 * cursor placement selects the level (point inside the inner node to get
	 * it, point where only the outer node reaches to get the outer).
	 *
	 * `equiv` (when supplied) widens the kind test through the grammar's
	 * kind-equivalence relation, exactly like `select` — so `atKind(_, _,
	 * 'FnMember', equiv)` also matches a `final` method's
	 * `FinalModifiedMember`. Returns null when no node of that kind covers
	 * the offset.
	 */
	public static function atKind(tree: QueryNode, offset: Int, kind: String, ?equiv: KindEquivalence): Null<QueryNode> {
		return atKindWalk(tree, offset, new SelectorSegment(kind, null), equiv, null, -1).node;
	}

	private static function truncateAt(node: QueryNode, depth: Int, maxDepth: Int): QueryNode {
		// Spans are preserved across `truncate` / `truncateChildren` —
		// `--spans` rendering needs them on every visible node, and
		// shaping is a display concern that should not strip source-
		// position info.
		if (depth >= maxDepth) return new QueryNode(node.kind, node.name, [], node.span);
		final kids: Array<QueryNode> = [for (c in node.children) truncateAt(c, depth + 1, maxDepth)];
		return new QueryNode(node.kind, node.name, kids, node.span);
	}

	private static function truncateChildrenAt(node: QueryNode, maxChildren: Int): QueryNode {
		final all: Array<QueryNode> = node.children;
		if (all.length <= maxChildren) {
			final kids: Array<QueryNode> = [for (c in all) truncateChildrenAt(c, maxChildren)];
			return new QueryNode(node.kind, node.name, kids, node.span);
		}
		final kept: Array<QueryNode> = [for (i in 0...maxChildren) truncateChildrenAt(all[i], maxChildren)];
		final omitted: Int = all.length - maxChildren;
		kept.push(new QueryNode('...', '$omitted more', []));
		return new QueryNode(node.kind, node.name, kept, node.span);
	}

	private static function walkSelect(node: QueryNode, sel: Selector, segIdx: Int, out: Array<QueryNode>, ?equiv: KindEquivalence): Void {
		// At each segIdx, try to match the current segment against `node`.
		// If matched and last segment: collect `node`. If matched and more segments:
		// recurse into children with segIdx+1.
		// Also, regardless of match, recurse into children with segIdx=0
		// so the first segment can fire deeper in the tree (top-level any-depth match).
		final matched: Bool = sel.segments[segIdx].matches(node, equiv);
		if (matched) {
			if (segIdx == sel.segments.length - 1) {
				out.push(node);
			} else {
				for (c in node.children) walkSelect(c, sel, segIdx + 1, out, equiv);
			}
		}
		if (segIdx == 0) for (c in node.children) walkSelect(c, sel, 0, out, equiv);
	}

	/**
	 * Pre-order accumulator walk: threads the best (innermost)
	 * containing node + its span width down the recursion. A child's
	 * span is nested within its parent's, so on equal width the
	 * later-visited (deeper) node replaces — yielding the innermost
	 * match. `width <= best` (not `<`) lets a deeper equal-width node
	 * (transparent single-child) win.
	 */
	private static function atWalk(
		node: QueryNode, offset: Int, best: Null<QueryNode>, bestWidth: Int
	): { node: Null<QueryNode>, width: Int } {
		var curBest: Null<QueryNode> = best;
		var curWidth: Int = bestWidth;
		final span: Null<Span> = node.span;
		if (span != null && offset >= span.from && offset < span.to) {
			final width: Int = span.to - span.from;
			if (curBest == null || width <= curWidth) {
				curBest = node;
				curWidth = width;
			}
		}
		for (c in node.children) {
			final r: { node: Null<QueryNode>, width: Int } = atWalk(c, offset, curBest, curWidth);
			curBest = r.node;
			curWidth = r.width;
		}
		return { node: curBest, width: curWidth };
	}

	/** `atWalk` with a kind filter (via `SelectorSegment.matches`) on the candidate test. */
	private static function atKindWalk(
		node: QueryNode, offset: Int, seg: SelectorSegment, equiv: Null<KindEquivalence>, best: Null<QueryNode>, bestWidth: Int
	): { node: Null<QueryNode>, width: Int } {
		var curBest: Null<QueryNode> = best;
		var curWidth: Int = bestWidth;
		final span: Null<Span> = node.span;
		if (span != null && offset >= span.from && offset < span.to && seg.matches(node, equiv)) {
			final width: Int = span.to - span.from;
			if (curBest == null || width <= curWidth) {
				curBest = node;
				curWidth = width;
			}
		}
		for (c in node.children) {
			final r: { node: Null<QueryNode>, width: Int } = atKindWalk(c, offset, seg, equiv, curBest, curWidth);
			curBest = r.node;
			curWidth = r.width;
		}
		return { node: curBest, width: curWidth };
	}

}
