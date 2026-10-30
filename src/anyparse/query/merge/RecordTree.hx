package anyparse.query.merge;

import anyparse.runtime.Span;

/**
 * A document read as a `MergeTree` by the spans of its nodes, for a data grammar whose lists are its structure (an
 * object's members, an array's elements): a container is a node whose children all carry spans, its head the text
 * before the first, its separator the text between the first two, its tail the text after the last. A named child (a
 * member) is keyed by its name and stands for its value; an unnamed one (an element) by the value of its first member
 * when every sibling's first member carries the same name — a record keyed by whatever field leads it — else by its
 * own text.
 */
@:nullSafety(Strict)
final class RecordTree {

	/** The separator of a container read with fewer than two children. */
	private static inline final DEFAULT_SEPARATOR: String = ', ';

	/** The tree of `source`, parsed into `root`. */
	public static function of(source: String, root: QueryNode): MergeTree {
		final tree: Null<MergeTree> = treeOf(source, valueOf(root, true), new Span(0, source.length), '');
		return tree ?? {
			head: source,
			children: [],
			separator: DEFAULT_SEPARATOR,
			tail: ''
		};
	}

	/** `node` past the single children a name or the document wraps around a value — a member to its value. */
	private static function valueOf(node: QueryNode, root: Bool): QueryNode {
		var at: QueryNode = node;
		var wrapped: Bool = root;
		while (at.children.length == 1 && (wrapped || at.name != null)) {
			at = at.children[0];
			wrapped = false;
		}
		return at;
	}

	/** The container `list` spanning `outer`, its children keyed under `path`; null when it holds none to key. */
	private static function treeOf(source: String, list: QueryNode, outer: Span, path: String): Null<MergeTree> {
		final spans: Array<Span> = [];
		for (item in list.children) {
			final span: Null<Span> = item.span;
			if (span == null) return null;
			spans.push(span);
		}
		if (spans.length == 0) return null;
		final ids: Array<String> = identities(source, list.children, path);
		final children: Array<MergeChild> = [
			for (i => item in list.children)
				{
					key: ids[i],
					lead: '',
					text: source.substring(spans[i].from, spans[i].to),
					tree: treeOf(source, valueOf(item, false), spans[i], ids[i]),
					seat: null
				}
		];
		return {
			head: source.substring(outer.from, spans[0].from),
			children: children,
			separator: spans.length > 1 ? source.substring(spans[0].to, spans[1].from) : DEFAULT_SEPARATOR,
			tail: source.substring(spans[spans.length - 1].to, outer.to)
		};
	}

	/** The key of each of `items` under `path`, a repeated one numbered from its second occurrence. */
	private static function identities(source: String, items: Array<QueryNode>, path: String): Array<String> {
		final lead: Null<String> = leadingName(items);
		final seen: Map<String, Int> = [];
		final out: Array<String> = [];
		for (item in items) {
			final name: Null<String> = item.name;
			final key: String = if (name != null)
				path == '' ? name : '$path.$name'
			else
				'$path[${lead == null ? textOf(source, item) : textOf(source, valueOf(item.children[0], false))}]';
			final count: Int = seen[key] ?? 0;
			seen[key] = count + 1;
			out.push(count == 0 ? key : '$key#${count + 1}');
		}
		return out;
	}

	/** The name every one of `items` leads with — the field a list of records is keyed by — or null when they differ. */
	private static function leadingName(items: Array<QueryNode>): Null<String> {
		var common: Null<String> = null;
		for (item in items) {
			final first: Null<QueryNode> = item.name == null && item.children.length > 0 ? item.children[0] : null;
			final name: Null<String> = first?.name;
			if (name == null || common != null && common != name) return null;
			common = name;
		}
		return common;
	}

	private static function textOf(source: String, node: QueryNode): String {
		final span: Null<Span> = node.span;
		return span == null ? node.kind : source.substring(span.from, span.to);
	}

}
