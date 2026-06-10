package anyparse.query;

import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.runtime.Span;

/**
 * Metadata-on-declaration walker for `apq meta`.
 *
 * Walks a `QueryNode` tree and collects every annotation node
 * (`kind ∈ shape.metaKinds`), attributing each to the declaration it
 * sits on. Annotations precede their declaration in source, so the
 * owner is the decl-host sibling whose span starts immediately after
 * the annotation — source order, NOT child-array order. The plugin's
 * flattened child order is not guaranteed to match source order
 * across constructs (e.g. the Haxe top-level wrapper emits the decl
 * before its metadata while the member wrapper emits metadata first),
 * but spans always reflect the source. When no following decl-host
 * sibling exists the annotation falls back to the nearest enclosing
 * decl-host ancestor — the documented v1 behaviour for
 * expression-level metadata, which attributes to its enclosing
 * declaration rather than a finer expression target.
 *
 * Language-agnostic: every decision is a string-kind compare or a
 * structural property of `QueryNode` (children present, `name`
 * containing `(`). The walker never inspects grammar-specific types.
 *
 * Annotation tag and arguments are derived structurally:
 *  - tag = `metaNode.name` truncated at the first `(` (the paren-less
 *    and paren-bearing forms both carry the bare tag before any `(`;
 *    the raw catch-all form carries `tag(args)` inline).
 *  - args = source slices of the annotation node's children when it
 *    has any (the structured paren-bearing form); otherwise the raw
 *    text between the first `(` and the last `)` of `name` as a
 *    single entry (the raw catch-all form); otherwise `[]`.
 */
@:nullSafety(Strict)
final class Meta {

	/**
	 * Walk `tree` and return every annotation hit per `shape`. Hits
	 * are returned in pre-order traversal. `source` is the parsed
	 * source string, used to slice argument text by child span.
	 */
	public static function find(tree: QueryNode, shape: MetaShape, source: String): Array<MetaHit> {
		final out: Array<MetaHit> = [];
		walk(tree, shape, source, null, out);
		return out;
	}

	private static function walk(
		node: QueryNode, shape: MetaShape, source: String, ancestorDecl: Null<QueryNode>, out: Array<MetaHit>
	): Void {
		final children: Array<QueryNode> = node.children;
		for (child in children) if (shape.metaKinds.contains(child.kind)) {
			final owner: Null<QueryNode> = followingDeclHost(children, child, shape) ?? ancestorDecl;
			if (owner != null) out.push(makeHit(child, owner, source));
		}
		final nextAncestor: Null<QueryNode> = shape.declHostKinds.contains(node.kind) ? node : ancestorDecl;
		for (c in children) walk(c, shape, source, nextAncestor, out);
	}

	private static function followingDeclHost(siblings: Array<QueryNode>, meta: QueryNode, shape: MetaShape): Null<QueryNode> {
		final metaSpan: Null<Span> = meta.span;
		if (metaSpan == null) return null;
		final after: Int = metaSpan.from;
		var best: Null<QueryNode> = null;
		var bestFrom: Int = 0;
		for (s in siblings) {
			if (!shape.declHostKinds.contains(s.kind)) continue;
			final ss: Null<Span> = s.span;
			if (ss == null || ss.from <= after) continue;
			if (best == null || ss.from < bestFrom) {
				best = s;
				bestFrom = ss.from;
			}
		}
		return best;
	}

	private static function makeHit(metaNode: QueryNode, owner: QueryNode, source: String): MetaHit {
		final rawName: String = metaNode.name ?? '';
		final parenIdx: Int = rawName.indexOf('(');
		final tag: String = StringTools.trim(parenIdx < 0 ? rawName : rawName.substring(0, parenIdx));
		final args: Array<String> = if (metaNode.children.length > 0) {
			[for (c in metaNode.children) StringTools.trim(sliceSpan(source, c.span))];
		} else if (parenIdx >= 0) {
			final closeIdx: Int = rawName.lastIndexOf(')');
			final raw: String = closeIdx > parenIdx ? rawName.substring(parenIdx + 1, closeIdx) : '';
			final trimmed: String = StringTools.trim(raw);
			trimmed.length == 0 ? [] : [trimmed];
		} else {
			[];
		}
		return {
			annotation: tag,
			args: args,
			declKind: owner.kind,
			declName: owner.name,
			declSpan: owner.span,
			metaSpan: metaNode.span,
		};
	}

	private static function sliceSpan(source: String, span: Null<Span>): String {
		if (span == null) return '';
		final from: Int = span.from < 0 ? 0 : span.from;
		final to: Int = span.to > source.length ? source.length : span.to;
		return from >= to ? '' : source.substring(from, to);
	}

}

/**
 * One annotation site discovered by `Meta.find`.
 *
 * `annotation` is the verbatim tag (e.g. `@:foo`), `args` the
 * per-argument source text (`[]` when the annotation takes none).
 * `declKind` / `declName` / `declSpan` describe the declaration the
 * annotation is attached to; `metaSpan` is the annotation node's own
 * span. Spans are `Null` for contract safety — in practice every
 * Haxe annotation and decl-host node carries one.
 */
typedef MetaHit = {
	var annotation: String;
	var args: Array<String>;
	var declKind: String;
	var declName: Null<String>;
	var declSpan: Null<Span>;
	var metaSpan: Null<Span>;
}
