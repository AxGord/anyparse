package anyparse.check.common.design.threads;

import anyparse.query.CallGraph;
import anyparse.query.TreePath;

/** The function nodes of a call graph, found in the branch-aware tree of their file, each tree projected once. */
@:nullSafety(Strict)
final class FunctionTrees {

	/** Each file's branch-aware tree, projected the first time a function in it is asked for; null for a file the graph cannot give. */
	private final _trees: Map<String, Null<QueryNode>> = [];

	/**
	 * `nodeAt`'s answers per `<file>\t<from>:<to>`, null included (no node spans it). The thread-safety passes ask
	 * for the same function again and again, and each ask was a descent through
	 * the file's tree; a tree is never re-projected, so an answer never goes stale.
	 */
	private final _nodes: Map<String, Null<QueryNode>> = [];

	private final _graph: CallGraph;
	private final _plugin: GrammarPlugin;

	public function new(graph: CallGraph, plugin: GrammarPlugin) {
		_graph = graph;
		_plugin = plugin;
	}

	/** The function node `edge` leaves, found in the tree of the edge's file; null when the graph holds no such node. */
	public inline function ofEdge(edge: CallEdge): Null<QueryNode> {
		return nodeAt(edge.file, _graph.node(edge.from)?.span);
	}

	/** The function node of the graph id `id`, found in the tree of its own file; null when the graph holds no such node. */
	public function ofId(id: String): Null<QueryNode> {
		final fn: Null<FnNode> = _graph.node(id);
		return fn == null ? null : nodeAt(fn.file, fn.span);
	}

	/** The branch-aware tree of the whole of `file`; null for a file the graph cannot give. */
	public function ofFile(file: String): Null<QueryNode> {
		if (!_trees.exists(file)) {
			final tree: Null<QueryNode> = _graph.treeOf(file);
			final source: Null<String> = _graph.sourceOf(file);
			_trees[file] = tree == null || source == null ? null : _plugin.projectBranchAware(tree, source);
		}
		return _trees[file];
	}

	/** The node of the tree of `file` spanning exactly `span`; null when there is none. */
	private function nodeAt(file: String, span: Null<Span>): Null<QueryNode> {
		if (span == null) return null;
		final key: String = '$file\t${span.from}:${span.to}';
		if (_nodes.exists(key)) return _nodes[key];
		final tree: Null<QueryNode> = ofFile(file);
		final node: Null<QueryNode> = tree == null ? null : TreePath.withSpan(tree, span);
		_nodes[key] = node;
		return node;
	}

}
