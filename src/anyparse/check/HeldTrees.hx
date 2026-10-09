package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/** A type's declaration node, the file holding it and that file's source. */
typedef HeldDecl = {
	final node: QueryNode;
	final file: String;
	final source: String;
}

/**
 * The trees a call graph parsed its files into (`CallGraph.heldFiles`), read once, and the lookups made in them by
 * position: the path down to a node, the graph function a node is, the one declaration of a type name.
 */
@:nullSafety(Strict)
final class HeldTrees {

	/** A type's name -> its declaration and the file holding it (`typeDecl`); null when not exactly one is held. */
	private final _decls: Map<String, Null<HeldDecl>> = [];

	private final _graph: CallGraph;

	/** The files of the graph with their trees, read once. */
	private var _held: Null<Array<{ file: String, source: String, tree: QueryNode }>> = null;

	/** Each held file -> its tree, filled on first use (`pathTo`). */
	private var _treeOf: Null<Map<String, QueryNode>> = null;

	public function new(graph: CallGraph) {
		_graph = graph;
	}

	/** The graph's files with their trees, read once. */
	public function files(): Array<{ file: String, source: String, tree: QueryNode }> {
		final known: Null<Array<{ file: String, source: String, tree: QueryNode }>> = _held;
		if (known != null) return known;
		final held: Array<{ file: String, source: String, tree: QueryNode }> = _graph.heldFiles();
		_held = held;
		return held;
	}

	/**
	 * The nodes of the tree of `file` from its root down to the one spanning exactly `span`, each enclosing the next;
	 * empty when no node spans it.
	 */
	public function pathTo(file: String, span: Span): Array<QueryNode> {
		var trees: Null<Map<String, QueryNode>> = _treeOf;
		if (trees == null) {
			final built: Map<String, QueryNode> = [for (held in files()) held.file => held.tree];
			_treeOf = built;
			trees = built;
		}
		final path: Array<QueryNode> = [];
		var node: Null<QueryNode> = trees[file];
		while (node != null) {
			path.push(node);
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to) return path;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return [];
	}

	/** The graph id of the function node `fn` of `file`: the graph's function spanning exactly its span; null for none. */
	public function functionOf(file: String, fn: QueryNode): Null<String> {
		final span: Null<Span> = fn.span;
		final id: Null<String> = span == null ? null : _graph.functionAt(file, span.from);
		final at: Null<Span> = id == null ? null : _graph.node(id)?.span;
		return span != null && at != null && at.from == span.from && at.to == span.to ? id : null;
	}

	/**
	 * The one declaration of the type named `type` the graph's files hold, a top-level one or one a module-level
	 * wrapper holds (`final class`); null when the project declares the name other than exactly once.
	 */
	public function typeDecl(type: String): Null<HeldDecl> {
		if (_decls.exists(type)) return _decls[type];
		final found: Array<HeldDecl> = [];
		for (held in files())
			for (top in held.tree.children)
				for (d in [top].concat(top.children))
					if (d.name == type && d.children.length > 0) found.push({ node: d, file: held.file, source: held.source });
		final decl: Null<HeldDecl> = found.length == 1 && _graph.types.declarationCount(type) == 1 ? found[0] : null;
		_decls[type] = decl;
		return decl;
	}

}
