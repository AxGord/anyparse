package anyparse.query;

import anyparse.runtime.Span;

/**
 * Navigation over a parsed tree: ancestors by reference IDENTITY, and the node at a range by SPAN.
 *
 * `QueryNode` carries no parent link, so "where does this node sit" is answered by
 * walking down from a root. Five private copies of that walk had accumulated across
 * `Address`, `CasePatternScan`, `RedundantReplaceLoop`, `DynamicBag` and
 * `RefactorSupport` - two of them byte-identical, the rest the same question in a
 * different signature. This is the one home for it.
 *
 * Identity is the right key for ancestry and a span is not: a declaration's span can co-start
 * with an inner node's, and two nodes can share a span outright, so a span lookup
 * answers a DIFFERENT question (see `JoinSingleUseLocal.pathToSpan`, which wants
 * exactly that one). That question has its home here too (`withSpan`, `firstAround`): three
 * private copies of the containment walk (`FunctionTrees`, `LockAliases`, `FunctionValueTypes`)
 * were folded into it.
 */
@:nullSafety(Strict)
final class TreePath {

	/**
	 * The root-to-`target` chain, inclusive of both ends - every element is a direct
	 * child of the one before it, which is what lets a caller split each level into the
	 * siblings before and after the path. Null when `target` is not in `root`.
	 */
	public static function pathTo(root: QueryNode, target: QueryNode): Null<Array<QueryNode>> {
		if (root == target) return [root];
		for (child in root.children) {
			final below: Null<Array<QueryNode>> = pathTo(child, target);
			if (below == null) continue;
			below.unshift(root);
			return below;
		}
		return null;
	}

	/** The parent of `target` in `root`, or null when `target` is the root or not present. */
	public static function parentOf(root: QueryNode, target: QueryNode): Null<QueryNode> {
		for (child in root.children) {
			if (child == target) return root;
			final found: Null<QueryNode> = parentOf(child, target);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * The outermost node of `root` spanning exactly `span` — of kind `kind` when one is given — or null. A span lookup,
	 * not an identity one: of two nodes sharing a span the enclosing one answers, unless `kind` names the inner one.
	 */
	public static function withSpan(root: QueryNode, span: Span, ?kind: String): Null<QueryNode> {
		return firstAround(root, span, n -> spansExactly(n, span) && (kind == null || n.kind == kind));
	}

	/**
	 * The first node of `root` in pre-order that `accept` takes, searching only the nodes whose span holds `span` (one
	 * carrying no span is searched through) — the walk under every "the node at this range" question, the test left to
	 * the caller.
	 */
	public static function firstAround(root: QueryNode, span: Span, accept: QueryNode -> Bool): Null<QueryNode> {
		final at: Null<Span> = root.span;
		if (at != null && (span.from < at.from || span.to > at.to)) return null;
		if (accept(root)) return root;
		for (child in root.children) {
			final found: Null<QueryNode> = firstAround(child, span, accept);
			if (found != null) return found;
		}
		return null;
	}

	/** Whether `node` carries exactly the range `span`. */
	public static function spansExactly(node: QueryNode, span: Span): Bool {
		final at: Null<Span> = node.span;
		return at != null && at.from == span.from && at.to == span.to;
	}

}
