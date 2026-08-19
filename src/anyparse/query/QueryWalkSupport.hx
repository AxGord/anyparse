package anyparse.query;

import anyparse.runtime.Span;

/**
 * Runtime helpers the GENERATED query walkers call (see
 * `anyparse.macro.QueryWalkerCodegen`). The generated code is per-grammar; these
 * helpers are not, so they live here instead of being re-emitted into every
 * marker class.
 */
@:nullSafety(Strict)
final class QueryWalkSupport {

	/**
	 * The first node of a one-slot accumulator, or null when nothing filled it.
	 *
	 * The generated walker hands a node-forming rule a private array for its
	 * `QueryNode.type` slot: a grammar field tagged `@:queryTypeSlot` pushes into it,
	 * every other field leaves it empty. An index read would be the same expression, but
	 * out of range it is target-defined - null on js, undefined behaviour on a static
	 * target - and the core has to answer the same on all of them.
	 */
	public static inline function first(nodes: Array<QueryNode>): Null<QueryNode> {
		return nodes.length > 0 ? nodes[0] : null;
	}

	/**
	 * Order a node's children by source position. The generated walker already
	 * emits fields in DECLARED order, which is deterministic on every target -
	 * unlike the reflective walker this replaced, whose `Reflect.fields` order
	 * was target-defined. The sort is kept because declared order is not always
	 * source order: a grammar may declare a field before one that parses
	 * earlier, and `apq ast` addresses nodes by position.
	 *
	 * Stable by original index on ties. Left untouched unless every child
	 * carries a span - a span-less node has no defined source position to order
	 * against.
	 */
	public static function orderBySpan(children: Array<QueryNode>): Array<QueryNode> {
		final indexed: Array<{ from: Int, idx: Int, node: QueryNode }> = [];
		for (i in 0...children.length) {
			final s: Null<Span> = children[i].span;
			if (s == null) return children;
			indexed.push({ from: s.from, idx: i, node: children[i] });
		}
		indexed.sort((a, b) -> a.from != b.from ? a.from - b.from : a.idx - b.idx);
		return [for (e in indexed) e.node];
	}

}
