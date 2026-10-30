package anyparse.query.graph;

import anyparse.query.graph.CodeGraph.GraphChange;
import anyparse.query.graph.CodeGraph.GraphEdge;
import anyparse.query.graph.CodeGraph.GraphNode;

/**
 * Two member graphs of one scope, at two versions, compared into one graph of what changed: each node and edge marked
 * by how it differs (`GraphChange`), an unchanged member folded into the type holding it. Knows no grammar: which
 * members' text changed is the caller's answer.
 */
@:nullSafety(Strict)
final class GraphDiff {

	/**
	 * The change from `before` to `after`, each holding every member its scope declares (`MemberGraphBuilder.declared`),
	 * `changed` naming the members whose text differs. A node only `after` holds is `Added`, one only `before` holds
	 * `Removed`, a member of both named in `changed` is `Changed`, and every other member folds into the node holding it.
	 * Edges are counted on the nodes their ends fold into, in each version, and compared by ends and kind: only in
	 * `after` `Added`, only in `before` `Removed`, of another weight `Changed`. The answer holds every changed node, the
	 * nodes holding it, and every edge that changed or touches a changed node; an edge between unchanged nodes is left out.
	 */
	public static function compare(before: CodeGraph, after: CodeGraph, changed: Array<String>): CodeGraph {
		final names: Map<String, Bool> = [for (name in changed) name => true];
		// node id -> how it differs, null when it does not
		final status: Map<String, Null<GraphChange>> = [];
		for (graph in [before, after]) for (n in graph.nodes()) if (!status.exists(n.id)) status[n.id] = changeOf(n, before, after, names);
		final out: CodeGraph = new CodeGraph();
		for (id => change in status) if (change != null) copy(before, after, out, id, status);
		final earlier: Map<String, GraphEdge> = foldedEdges(before, status);
		final later: Map<String, GraphEdge> = foldedEdges(after, status);
		final keys: Array<String> = [for (key in earlier.keys()) key];
		for (key in later.keys()) if (!earlier.exists(key)) keys.push(key);
		for (key in keys) {
			final was: Null<GraphEdge> = earlier[key];
			final now: Null<GraphEdge> = later[key];
			final e: Null<GraphEdge> = now ?? was;
			if (e == null) continue;
			final change: Null<GraphChange> = edgeChange(was, now);
			if (change == null && status[e.from] == null && status[e.to] == null) continue;
			final from: String = copy(before, after, out, e.from, status);
			final to: String = copy(before, after, out, e.to, status);
			out.addEdge(from, to, e.kind, e.weight);
			final drawn: Null<GraphEdge> = out.edge(from, to, e.kind);
			if (drawn == null || change == null) continue;
			drawn.change = change;
			if (change == Changed && was != null) drawn.before = was.weight;
		}
		return out;
	}

	/** How an edge `was` in the earlier version and is `now` in the later differs; null when it does not. */
	private static function edgeChange(was: Null<GraphEdge>, now: Null<GraphEdge>): Null<GraphChange> {
		return if (was == null)
			Added
		else if (now == null)
			Removed
		else if (was.weight != now.weight)
			Changed
		else
			null;
	}

	/** How `n` differs between the two versions; null for a node outside the scope, which neither declares. */
	private static function changeOf(n: GraphNode, before: CodeGraph, after: CodeGraph, names: Map<String, Bool>): Null<GraphChange> {
		if (n.external) return null;
		return if (before.node(n.id) == null)
			Added
		else if (after.node(n.id) == null)
			Removed
		else if (n.level == Member && names.exists(n.name))
			Changed
		else
			null;
	}

	/** The node `id` folds into: the node holding it for an unchanged member, else itself. */
	private static function folded(graph: CodeGraph, id: String, status: Map<String, Null<GraphChange>>): String {
		final n: Null<GraphNode> = graph.node(id);
		return n == null || n.level != Member || status[id] != null ? id : n.parent ?? id;
	}

	/**
	 * The edges of `graph` on the nodes their ends fold into, weights summed per ends and kind, keyed so. An edge whose
	 * ends fold into one node is dropped unless it is that node's own recursion.
	 */
	private static function foldedEdges(graph: CodeGraph, status: Map<String, Null<GraphChange>>): Map<String, GraphEdge> {
		final out: Map<String, GraphEdge> = [];
		for (e in graph.edges()) {
			final from: String = folded(graph, e.from, status);
			final to: String = folded(graph, e.to, status);
			if (from == to && (e.from != e.to || e.from != from)) continue;
			final key: String = '$from $to ${e.kind}';
			final existing: Null<GraphEdge> = out[key];
			if (existing != null) {
				existing.weight += e.weight;
				continue;
			}
			final first: GraphEdge = {
				from: from,
				to: to,
				kind: e.kind,
				weight: e.weight
			};
			out[key] = first;
		}
		return out;
	}

	/** Add the node `id` to `out` with the nodes holding it, each marked by its change, as the later version holding it says. */
	private static function copy(
		before: CodeGraph, after: CodeGraph, out: CodeGraph, id: String, status: Map<String, Null<GraphChange>>
	): String {
		final n: Null<GraphNode> = after.node(id) ?? before.node(id);
		if (n == null) throw new Exception('graph: no node $id in either version');
		final parent: Null<String> = n.parent;
		final parentId: Null<String> = parent == null ? null : copy(before, after, out, parent, status);
		final added: String = out.addNode(n.level, n.name, n.label, parentId, n.external);
		final change: Null<GraphChange> = status[id];
		final drawn: Null<GraphNode> = out.node(added);
		if (change != null && drawn != null) drawn.change = change;
		return added;
	}

}
