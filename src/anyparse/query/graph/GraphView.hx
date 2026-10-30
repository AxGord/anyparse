package anyparse.query.graph;

import anyparse.query.graph.CodeGraph.GraphChange;
import anyparse.query.graph.CodeGraph.GraphEdge;
import anyparse.query.graph.CodeGraph.GraphEdgeKind;
import anyparse.query.graph.CodeGraph.GraphLevel;
import anyparse.query.graph.CodeGraph.GraphNode;

using Lambda;

/**
 * What a view keeps of a graph: a weight floor, the nodes to centre on and
 * how far to reach from them, mutual pairs only, the nodes outside the scope.
 */
typedef GraphFilter = {

	/** The least weight a direction of a pair must carry to be drawn; 1 keeps every edge. */
	final minWeight: Int;

	/** The ids of the nodes to centre on; none keeps the whole graph. */
	final focus: Array<String>;

	/** How many edges, either way, a node kept may lie from a focus node. */
	final radius: Int;

	/** Keep only the edges whose ends depend on each other. */
	final mutualOnly: Bool;

	/** Keep the nodes outside the scanned scope and the edges reaching them. */
	final external: Bool;
}

/**
 * The edges of a graph a view folds onto one pair of ends and one kind, summed on each side of a graph comparing two
 * versions: what the later version weighs and whether it holds any of them, and the same of the earlier.
 */
private typedef FoldedEdge = {
	final from: String;
	final to: String;
	final kind: GraphEdgeKind;
	var after: Int;
	var inAfter: Bool;
	var before: Int;
	var inBefore: Bool;
}

/**
 * Views of a `CodeGraph`: the graph lifted to a coarser level or opened node by node, and the graph pruned by a
 * `GraphFilter`. Each answers a new graph and leaves its input as it was; a node keeps its id, so a view and its source
 * name a declaration alike. A view of a graph comparing two versions (`GraphDiff`) keeps the change: a node holding a
 * changed node, or a changed edge folded shut inside it, is changed itself, and an edge folded from several is weighed
 * on each version's side.
 */
@:nullSafety(Strict)
final class GraphView {

	/**
	 * `graph` at `level`: each node folds into its nearest ancestor-or-self at that level, and an edge counts on the nodes
	 * its ends fold into, weights summed per kind. An edge whose ends fold into one node is dropped unless that node is its
	 * own end, a recursion at the level; a node with no ancestor at the level (an external type at the package level, a
	 * member no type declares) is left out with its edges.
	 */
	public static function lift(graph: CodeGraph, level: GraphLevel): CodeGraph {
		return foldInto(graph, n -> ancestorAt(graph, n, level));
	}

	/**
	 * `graph` with the nodes of `open` opened, the view of a reader drilling down: each node folds into the outermost of
	 * itself and the nodes holding it that is not open, so a closed node stands whole and an open one shows what it holds,
	 * and an edge folds as `lift` folds it. An open node itself stays, holding what it shows.
	 */
	public static function opened(graph: CodeGraph, open: Map<String, Bool>): CodeGraph {
		return foldInto(graph, n -> outermostClosed(graph, n, open));
	}

	/**
	 * The part of `opened(graph, open)` that `holder`, a node of `open` with the nodes holding it, opens: the nodes it
	 * holds and every edge with an end inside it, each end folded as `opened` folds it. It walks what `holder` holds and
	 * the edges touching that, never the whole graph, so a view per node of a large graph stays cheap.
	 */
	public static function opening(graph: CodeGraph, holder: String, open: Map<String, Bool>): CodeGraph {
		final view: CodeGraph = new CodeGraph();
		final within: Map<String, Null<GraphChange>> = [];
		for (n in graph.held(holder)) copy(graph, view, n, within);
		final inside: Map<String, Bool> = [];
		final pending: Array<String> = [holder];
		while (pending.length > 0) for (n in graph.held(pending.pop() ?? '')) {
			inside[n.id] = true;
			pending.push(n.id);
		}
		final sums: Map<String, FoldedEdge> = [];
		for (id in inside.keys()) for (e in graph.touching(id)) {
			// an edge between two nodes inside is counted from its source alone
			if (e.from != id && inside.exists(e.from)) continue;
			final from: String = copy(graph, view, outermostClosed(graph, nodeOf(graph, e.from), open), within);
			final to: String = copy(graph, view, outermostClosed(graph, nodeOf(graph, e.to), open), within);
			if (from != to || isOwnRecursion(e, from))
				fold(sums, from, to, e)
			else if (e.change != null)
				markChanged(view, from);
		}
		drawFolded(view, sums);
		return view;
	}

	/**
	 * `graph` with every package of more than `depth` dotted segments folded into its ancestor of `depth` segments
	 * (`anyparse.query.cli` into `anyparse.query` at depth 2): what a folded package held nests in the ancestor, edges
	 * between packages folding into one are summed as `lift` sums them, and the types and members keep their ids.
	 */
	public static function foldPackages(graph: CodeGraph, depth: Int): CodeGraph {
		final folded: CodeGraph = new CodeGraph();
		for (n in graph.nodes()) {
			final id: String = copyFolded(graph, folded, n, depth);
			if (n.focus) folded.markFocus(id);
		}
		for (e in graph.edges()) {
			final from: String = copyFolded(graph, folded, nodeOf(graph, e.from), depth);
			final to: String = copyFolded(graph, folded, nodeOf(graph, e.to), depth);
			if (from != to || isOwnRecursion(e, from)) folded.addEdge(from, to, e.kind, e.weight);
		}
		return folded;
	}

	/**
	 * `graph` pruned by `filter`. A direction of a pair is drawn when its weight, every kind summed, reaches `minWeight` —
	 * or when the other direction's does, so a weak edge back is never hidden behind a strong one: that back edge is the
	 * cycle the view exists to show. Around `focus` the view keeps what lies within `radius` edges of a focus node, either
	 * way, over the edges drawn. A node outside the scope is left out with its edges unless the filter
	 * keeps them. With any filter the nodes kept are the ends of the edges drawn and the focus nodes, which
	 * the view marks; with none the graph is copied whole.
	 */
	public static function filter(graph: CodeGraph, filter: GraphFilter): CodeGraph {
		final view: CodeGraph = new CodeGraph();
		final kept: Array<GraphEdge> = graph.edges().filter(
			e ->
				(filter.external || (!nodeOf(graph, e.from).external && !nodeOf(graph, e.to).external))
				&& (!filter.mutualOnly || graph.isMutual(e))
				&& (graph.weightBetween(e.from, e.to) >= filter.minWeight || graph.weightBetween(e.to, e.from) >= filter.minWeight)
		);
		final reached: Null<Map<String, Bool>> = filter.focus.length == 0 ? null : around(filter.focus, kept, filter.radius);
		final pruned: Bool = reached != null || filter.minWeight > 1 || filter.mutualOnly;
		final within: Map<String, Null<GraphChange>> = [];
		if (!pruned) for (n in graph.nodes()) if (filter.external || !n.external) copy(graph, view, n, within);
		for (id in filter.focus) {
			final n: Null<GraphNode> = graph.node(id);
			if (n == null) throw new Exception('graph: no focus node $id');
			view.markFocus(copy(graph, view, n, within));
		}
		final sums: Map<String, FoldedEdge> = [];
		for (e in kept) if (reached == null || (reached.exists(e.from) && reached.exists(e.to))) {
			fold(sums, copy(graph, view, nodeOf(graph, e.from), within), copy(graph, view, nodeOf(graph, e.to), within), e);
		}
		drawFolded(view, sums);
		return view;
	}

	/**
	 * The nodes at `level` a reader's `query` names: those whose qualified name is the query, else those whose name ends
	 * with it after a dot (`Alpha.run` names `pkg.a.Alpha.run`, `query` names `anyparse.query`). A node of another level
	 * — the package a lift brings in above a type — is never named. Ordered by id.
	 */
	public static function named(graph: CodeGraph, query: String, level: GraphLevel): Array<GraphNode> {
		final all: Array<GraphNode> = graph.nodes().filter(n -> n.level == level);
		final exact: Array<GraphNode> = all.filter(n -> n.name == query);
		return exact.length > 0 ? exact : all.filter(n -> n.name.endsWith('.$query'));
	}

	/** Whether `e`, both of whose ends fold into `into`, is the recursion of `into` itself rather than an edge folded shut. */
	private static inline function isOwnRecursion(e: GraphEdge, into: String): Bool {
		return e.from == e.to && e.from == into;
	}

	/**
	 * `graph` with each node folded into the node `into` answers for it, or left out with its edges when it answers null;
	 * an edge counts on the nodes its ends fold into, weights summed per kind, and one whose ends fold into one node is
	 * dropped unless that node is its own end.
	 */
	private static function foldInto(graph: CodeGraph, into: (n:GraphNode) -> Null<GraphNode>): CodeGraph {
		final lifted: CodeGraph = new CodeGraph();
		// node id -> the id it folds into, null when it folds into none
		final folded: Map<String, Null<String>> = [];
		final within: Map<String, Null<GraphChange>> = [];
		for (n in graph.nodes()) {
			final target: Null<GraphNode> = into(n);
			folded[n.id] = target == null ? null : copy(graph, lifted, target, within);
			if (target != null && n.focus) lifted.markFocus(target.id);
		}
		final sums: Map<String, FoldedEdge> = [];
		for (e in graph.edges()) {
			final from: Null<String> = folded[e.from];
			final to: Null<String> = folded[e.to];
			if (from == null || to == null) continue;
			if (from != to || isOwnRecursion(e, from))
				fold(sums, from, to, e)
			else if (e.change != null)
				markChanged(lifted, from);
		}
		drawFolded(lifted, sums);
		return lifted;
	}

	/** The outermost of `n` and the nodes holding it that is not in `open`; `n` itself when every one of them is. */
	private static function outermostClosed(graph: CodeGraph, n: GraphNode, open: Map<String, Bool>): GraphNode {
		final chain: Array<GraphNode> = [n];
		var parent: Null<String> = n.parent;
		while (parent != null) {
			final holder: GraphNode = nodeOf(graph, parent);
			chain.push(holder);
			parent = holder.parent;
		}
		chain.reverse();
		return chain.find(c -> !open.exists(c.id)) ?? n;
	}

	/** Every node within `radius` edges of a node of `seeds`, the edges walked either way. */
	private static function around(seeds: Array<String>, edges: Array<GraphEdge>, radius: Int): Map<String, Bool> {
		final adjacent: Map<String, Array<String>> = [];
		for (e in edges) {
			link(adjacent, e.from, e.to);
			link(adjacent, e.to, e.from);
		}
		final reached: Map<String, Bool> = [];
		var frontier: Array<String> = [];
		for (s in seeds) if (!reached.exists(s)) {
			reached[s] = true;
			frontier.push(s);
		}
		for (_ in 0...radius) {
			final next: Array<String> = [];
			for (id in frontier) for (other in adjacent[id] ?? []) if (!reached.exists(other)) {
				reached[other] = true;
				next.push(other);
			}
			frontier = next;
		}
		return reached;
	}

	private static function link(adjacent: Map<String, Array<String>>, from: String, to: String): Void {
		final list: Null<Array<String>> = adjacent[from];
		if (list == null)
			adjacent[from] = [to]
		else
			list.push(to);
	}

	/** The nearest of `n` and the nodes holding it that stands at `level`, or null. */
	private static function ancestorAt(graph: CodeGraph, n: GraphNode, level: GraphLevel): Null<GraphNode> {
		var current: Null<GraphNode> = n;
		while (current != null) {
			if (current.level == level) return current;
			final parent: Null<String> = current.parent;
			current = parent == null ? null : graph.node(parent);
		}
		return null;
	}

	/** `copy` with every package folded to its first `depth` segments (`foldPackages`). */
	private static function copyFolded(source: CodeGraph, target: CodeGraph, n: GraphNode, depth: Int): String {
		if (n.level == Package) {
			final segments: Array<String> = n.name.split('.');
			if (segments.length > depth) {
				final name: String = segments.slice(0, depth).join('.');
				return target.addNode(Package, name, name, null, n.external);
			}
		}
		final parent: Null<String> = n.parent;
		final parentId: Null<String> = parent == null ? null : copyFolded(source, target, nodeOf(source, parent), depth);
		return target.addNode(n.level, n.name, n.label, parentId, n.external);
	}

	/**
	 * Add `n` of `source` to `target` with the nodes holding it, unless `target` holds it, and answer its id. Each node
	 * added carries its change in a graph comparing two versions, or `Changed` when it has none and a node it holds has one
	 * (`changeWithin`).
	 */
	private static function copy(source: CodeGraph, target: CodeGraph, n: GraphNode, within: Map<String, Null<GraphChange>>): String {
		final parent: Null<String> = n.parent;
		final parentId: Null<String> = parent == null ? null : copy(source, target, nodeOf(source, parent), within);
		final id: String = target.addNode(n.level, n.name, n.label, parentId, n.external);
		final change: Null<GraphChange> = changeWithin(source, n, within);
		final drawn: Null<GraphNode> = target.node(id);
		if (change != null && drawn != null) drawn.change = change;
		return id;
	}

	private static function nodeOf(graph: CodeGraph, id: String): GraphNode {
		final n: Null<GraphNode> = graph.node(id);
		if (n == null) throw new Exception('graph: no node $id');
		return n;
	}

	/**
	 * How `n` differs in a graph comparing two versions: its own change, else `Changed` when a node it holds, at any depth,
	 * differs, else null. `within` remembers the answer for each node walked without a change of its own.
	 */
	private static function changeWithin(graph: CodeGraph, n: GraphNode, within: Map<String, Null<GraphChange>>): Null<GraphChange> {
		final own: Null<GraphChange> = n.change;
		if (own != null) return own;
		if (within.exists(n.id)) return within[n.id];
		var found: Null<GraphChange> = null;
		for (c in graph.held(n.id)) if (changeWithin(graph, c, within) != null) {
			found = Changed;
			break;
		}
		within[n.id] = found;
		return found;
	}

	/** Count `e` of `graph` on `from` and `to`, the nodes its ends fold into, in `sums`, on the side of each version holding it. */
	private static function fold(sums: Map<String, FoldedEdge>, from: String, to: String, e: GraphEdge): Void {
		final key: String = '$from $to ${e.kind}';
		var sum: Null<FoldedEdge> = sums[key];
		if (sum == null) {
			final opened: FoldedEdge = {
				from: from,
				to: to,
				kind: e.kind,
				after: 0,
				inAfter: false,
				before: 0,
				inBefore: false
			};
			sums[key] = opened;
			sum = opened;
		}
		final change: Null<GraphChange> = e.change;
		if (change != Removed) {
			sum.after += e.weight;
			sum.inAfter = true;
		}
		if (change == Added) return;
		sum.before += change == Changed ? (e.before ?? e.weight) : e.weight;
		sum.inBefore = true;
	}

	/**
	 * Add each edge of `sums` to `view`: `Added` when no edge folded into it is in the earlier version, `Removed` when none
	 * is in the later, `Changed` when the two versions weigh it apart, the earlier weight kept; its weight the later
	 * version's, or the earlier's for a removed one.
	 */
	private static function drawFolded(view: CodeGraph, sums: Map<String, FoldedEdge>): Void {
		for (sum in sums) {
			final change: Null<GraphChange> = if (!sum.inBefore)
				Added
			else if (!sum.inAfter)
				Removed
			else if (sum.before != sum.after)
				Changed
			else
				null;
			view.addEdge(sum.from, sum.to, sum.kind, change == Removed ? sum.before : sum.after);
			final drawn: Null<GraphEdge> = view.edge(sum.from, sum.to, sum.kind);
			if (drawn == null || change == null) continue;
			drawn.change = change;
			if (change == Changed) drawn.before = sum.before;
		}
	}

	/**
	 * Mark the node `id` of `view` and every node holding it `Changed` where it has no change of its own: a changed edge
	 * folded shut inside a node is a change that node holds, which `changeWithin`, walking nodes alone, does not see.
	 */
	private static function markChanged(view: CodeGraph, id: String): Void {
		var current: Null<GraphNode> = view.node(id);
		while (current != null) {
			if (current.change == null) current.change = Changed;
			final parent: Null<String> = current.parent;
			current = parent == null ? null : view.node(parent);
		}
	}

}
