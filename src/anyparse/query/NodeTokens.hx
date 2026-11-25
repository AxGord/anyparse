package anyparse.query;

import anyparse.runtime.Span;
import anyparse.runtime.TokenLog;
import anyparse.util.Compare;

/**
 * The one answer to "which literals did the parse match for this node itself": the tokens of its parse's `TokenLog`
 * that fall inside the node's own span and outside every child's and its type slot's (`QueryNode.tokenSpans`). The
 * deepest node covering a token owns it, so a node a projection made transparent leaves its tokens to the nearest
 * node that stayed. Generic over grammars: the log is what the generated parser matched and the tree is what the
 * generated walker projected, so no grammar names a token here.
 *
 * A node holds only the tree's shared log and answers on demand, since a token array per node would cost more than the
 * log it is cut from.
 */
@:nullSafety(Strict)
final class NodeTokens {

	/** Hand `log` to every node of `tree`; a null `log` (a parse that kept none) hands nothing. */
	public static function attach(tree: QueryNode, log: Null<TokenLog>): Void {
		if (log == null) return;
		tree.attachTokens(log);
		for (part in partsOf(tree)) attach(part, log);
	}

	/** The tokens of `log` inside `node`'s extent and outside every part's, in source order. */
	public static function ownOf(node: QueryNode, log: TokenLog): Array<Span> {
		final own: Array<Span> = [];
		final extent: Null<Span> = extentOf(node);
		if (extent == null) return own;
		final hi: Int = log.firstAtOrAfter(extent.to, 0, log.count());
		var cursor: Int = log.firstAtOrAfter(extent.from, 0, hi);
		for (part in partsOf(node)) {
			final inner: Null<Span> = extentOf(part);
			if (inner == null) continue;
			final start: Int = log.firstAtOrAfter(inner.from, cursor, hi);
			for (index in cursor ... start) own.push(new Span(log.fromAt(index), log.toAt(index)));
			cursor = log.firstAtOrAfter(inner.to, start, hi);
		}
		for (index in cursor ... hi) own.push(new Span(log.fromAt(index), log.toAt(index)));
		return own;
	}

	/** The offset of the first of `node`'s own tokens that spells `text`, or -1 when none does or its tree kept no log. */
	public static function firstSpelling(node: QueryNode, source: String, text: String): Int {
		for (span in node.tokenSpans()) if (spells(span, source, text)) return span.from;
		return -1;
	}

	/** The offset of the last of `node`'s own tokens that spells `text`, or -1 when none does or its tree kept no log. */
	public static function lastSpelling(node: QueryNode, source: String, text: String): Int {
		final own: Array<Span> = node.tokenSpans();
		var index: Int = own.length - 1;
		while (index >= 0 && !spells(own[index], source, text)) index--;
		return index < 0 ? -1 : own[index].from;
	}

	/**
	 * Whether `node`'s last own token spells `text` and closes the node's span — a statement that ends in its own
	 * terminator, not in a child's; false when its tree kept no log.
	 */
	public static function endsWithOwn(node: QueryNode, source: String, text: String): Bool {
		final span: Null<Span> = node.span;
		final own: Array<Span> = node.tokenSpans();
		return span != null && own.length > 0 && own[own.length - 1].to == span.to && spells(own[own.length - 1], source, text);
	}

	/** `node`'s children and its type slot, in source order. */
	private static function partsOf(node: QueryNode): Array<QueryNode> {
		final type: Null<QueryNode> = node.type;
		if (type == null) return node.children;
		final parts: Array<QueryNode> = node.children.concat([type]);
		parts.sort((a, b) -> Compare.compareInt(startOf(a), startOf(b)));
		return parts;
	}

	private static function startOf(node: QueryNode): Int {
		return extentOf(node)?.from ?? -1;
	}

	/** `node`'s span, or for a node projected without one the extent of its parts; null when nothing in it has a span. */
	private static function extentOf(node: QueryNode): Null<Span> {
		final span: Null<Span> = node.span;
		if (span != null) return span;
		var from: Int = -1;
		var to: Int = -1;
		for (part in partsOf(node)) {
			final inner: Null<Span> = extentOf(part);
			if (inner == null) continue;
			if (from < 0 || inner.from < from) from = inner.from;
			if (inner.to > to) to = inner.to;
		}
		return from < 0 ? null : new Span(from, to);
	}

	private static function spells(span: Span, source: String, text: String): Bool {
		return span.to - span.from == text.length && source.substring(span.from, span.to) == text;
	}

}
