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
