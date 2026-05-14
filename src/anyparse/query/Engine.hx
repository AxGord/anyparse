package anyparse.query;

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
	public static function truncate(node:QueryNode, maxDepth:Int):QueryNode {
		return maxDepth < 0 ? node : truncateAt(node, 0, maxDepth);
	}

	/**
	 * Walk `tree` and return every node that matches `selector`.
	 * Combinators in `selector` walk left-to-right; only direct-child
	 * relationships are tested per the v1 selector spec.
	 */
	public static function select(tree:QueryNode, selector:Selector):Array<QueryNode> {
		final out:Array<QueryNode> = [];
		walkSelect(tree, selector, 0, out);
		return out;
	}

	private static function truncateAt(node:QueryNode, depth:Int, maxDepth:Int):QueryNode {
		if (depth >= maxDepth) return new QueryNode(node.kind, node.name, []);
		final kids:Array<QueryNode> = [for (c in node.children) truncateAt(c, depth + 1, maxDepth)];
		return new QueryNode(node.kind, node.name, kids);
	}

	private static function walkSelect(node:QueryNode, sel:Selector, segIdx:Int, out:Array<QueryNode>):Void {
		// At each segIdx, try to match the current segment against `node`.
		// If matched and last segment: collect `node`. If matched and more segments:
		// recurse into children with segIdx+1.
		// Also, regardless of match, recurse into children with segIdx=0
		// so the first segment can fire deeper in the tree (top-level any-depth match).
		final matched:Bool = sel.segments[segIdx].matches(node);
		if (matched) {
			if (segIdx == sel.segments.length - 1) {
				out.push(node);
			} else {
				for (c in node.children) walkSelect(c, sel, segIdx + 1, out);
			}
		}
		if (segIdx == 0) for (c in node.children) walkSelect(c, sel, 0, out);
	}
}
