package anyparse.query;

/**
 * Ancestor navigation over a parsed tree, by reference IDENTITY.
 *
 * `QueryNode` carries no parent link, so "where does this node sit" is answered by
 * walking down from a root. Five private copies of that walk had accumulated across
 * `Address`, `CasePatternScan`, `RedundantReplaceLoop`, `DynamicBag` and
 * `RefactorSupport` - two of them byte-identical, the rest the same question in a
 * different signature. This is the one home for it.
 *
 * Identity is the right key here and a span is not: a declaration's span can co-start
 * with an inner node's, and two nodes can share a span outright, so a span lookup
 * answers a DIFFERENT question (see `JoinSingleUseLocal.pathToSpan`, which wants
 * exactly that one).
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

}
