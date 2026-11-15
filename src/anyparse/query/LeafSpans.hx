package anyparse.query;

import anyparse.runtime.Span;

/**
 * The one answer to "which spans are the leaves of a parsed subtree": every childless node's span, in document order.
 * A leaf is a node with no structure projected inside it, which may be one token or a childless multi-token node.
 */
@:nullSafety(Strict)
final class LeafSpans {

	/** Append the span of every leaf in `node`'s subtree to `out`, in document order, and return `out`. */
	public static function collect(node: QueryNode, out: Array<Span>): Array<Span> {
		if (node.children.length == 0) {
			final span: Null<Span> = node.span;
			if (span != null) out.push(span);
			return out;
		}
		for (child in node.children) collect(child, out);
		return out;
	}

}
