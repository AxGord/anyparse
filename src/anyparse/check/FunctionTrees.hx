package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/** The function nodes of a call graph, found in the branch-aware tree of their file, each tree projected once. */
@:nullSafety(Strict)
final class FunctionTrees {

	/** Each file's branch-aware tree, projected the first time a function in it is asked for; null for a file the graph cannot give. */
	private final _trees: Map<String, Null<QueryNode>> = [];

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
		var node: Null<QueryNode> = ofFile(file);
		while (node != null) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to) return node;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

}
