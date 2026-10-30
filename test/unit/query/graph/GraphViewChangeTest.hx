package unit.query.graph;

import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.GraphView;

/**
 * `GraphView` over a graph comparing two versions: each view keeps what changed — a node its own change, a node holding
 * a changed one `Changed`, an edge folded from several weighed on each version's side — and the input stays as it was.
 */
@:nullSafety(Strict)
class GraphViewChangeTest extends Test {

	/** A node folded or opened keeps its own change; one holding a changed node is changed; one holding none is not. */
	@:killer('M-GRAPH-VIEW-HOLDER-UNCHANGED')
	@:pin('control')
	public function testAHolderIsChangedByWhatItHolds(): Void {
		final graph: CodeGraph = compared();
		Assert.equals('p.x ~|p.y ~|p.x.X ~|p.y.Y =|p.y.Z +', changes(GraphView.lift(graph, Type)));
		Assert.equals('p.x ~|p.y ~', changes(GraphView.lift(graph, Package)));
		final open: Map<String, Bool> = [CodeGraph.idOf(Package, 'p.x') => true];
		Assert.equals('p.x ~|p.y ~|p.x.X ~', changes(GraphView.opened(graph, open)), 'an opened holder is signed too');
		Assert.equals(
			'p.x.X.a ~|p.x.X.b -|p.y.Y.c =|p.y.Z.e +|p.x =|p.y =|p.x.X =|p.y.Y =|p.y.Z +', changes(graph), 'the input stays as it was'
		);
	}

	/**
	 * Edges folded onto one pair and kind are summed on each version's side: added where none was before, removed where
	 * none is after, changed where the sums differ, and unchanged where an edge added and one removed weigh alike.
	 */
	@:killer('M-GRAPH-VIEW-FOLD-UNSUMMED')
	@:pin('control')
	public function testAFoldedEdgeIsWeighedOnEachSide(): Void {
		Assert.equals(
			'p.x.X -> p.y.Y call 3 changed was 2|p.x.X -> p.y.Y new 2 added|p.x.X -> p.y.Y ref 1 removed|p.x.X -> p.y.Y virtual 1 -',
			edges(GraphView.lift(compared(), Type))
		);
	}

	/** A view opened at a type keeps its members' changes and folds what lies outside as `opened` folds it. */
	public function testAnOpeningKeepsTheChangesInside(): Void {
		final x: String = CodeGraph.idOf(Type, 'p.x.X');
		final open: Map<String, Bool> = [CodeGraph.idOf(Package, 'p.x') => true, x => true];
		final view: CodeGraph = GraphView.opening(compared(), x, open);
		Assert.equals('p.x.X.a ~|p.x.X.b -|p.x ~|p.y ~|p.x.X ~', changes(view));
		Assert.equals(
			'p.x.X.a -> p.y call 3 changed was 1|p.x.X.a -> p.y new 1 added|p.x.X.a -> p.y virtual 1 added|'
			+ 'p.x.X.b -> p.y call 1 removed|p.x.X.b -> p.y new 1 added|p.x.X.b -> p.y ref 1 removed|p.x.X.b -> p.y virtual 1 removed',
			edges(view)
		);
	}

	/** A filter copies each edge's change and earlier weight as they stand, and signs a node holding a changed one. */
	@:killer('M-GRAPH-VIEW-EDGE-CHANGE-DROPPED')
	@:pin('control')
	public function testAFilterKeepsTheChange(): Void {
		final graph: CodeGraph = compared();
		final view: CodeGraph = GraphView.filter(graph, {
			minWeight: 1,
			focus: [],
			radius: 0,
			mutualOnly: false,
			external: false
		});
		Assert.equals(edges(graph), edges(view));
		Assert.equals('p.x.X.a ~|p.x.X.b -|p.y.Y.c =|p.y.Z.e +|p.x ~|p.y ~|p.x.X ~|p.y.Y =|p.y.Z +', changes(view));
	}

	/**
	 * A changed edge between two unchanged nodes that fold into one is no edge of the view, but a change the node holds:
	 * that node and every node holding it are changed, whether lifted or opened.
	 */
	@:killer('M-GRAPH-VIEW-SHUT-EDGE-UNMARKED')
	@:pin('control')
	public function testAChangedEdgeFoldedShutChangesItsHolder(): Void {
		final types: CodeGraph = new CodeGraph();
		final p: String = types.addNode(Package, 'p', 'p', null, false);
		final a: String = types.addNode(Type, 'p.A', 'A', p, false);
		final b: String = types.addNode(Type, 'p.B', 'B', p, false);
		edge(types, a, b, Call, 1, Added, null);
		Assert.equals('p ~', changes(GraphView.lift(types, Package)));
		final members: CodeGraph = new CodeGraph();
		final q: String = members.addNode(Package, 'p', 'p', null, false);
		final t: String = members.addNode(Type, 'p.A', 'A', q, false);
		final f: String = members.addNode(Member, 'p.A.f', 'f', t, false);
		final g: String = members.addNode(Member, 'p.A.g', 'g', t, false);
		edge(members, f, g, Call, 1, Added, null);
		Assert.equals('p ~|p.A ~', changes(GraphView.lift(members, Type)));
		Assert.equals('p ~|p.A ~', changes(GraphView.opening(members, q, [q => true])));
	}

	/**
	 * Two packages: `p.x.X` holds `a`, changed, and `b`, removed; `p.y.Y` holds `c`, unchanged; `p.y.Z` is added with its
	 * member `e`. The edges from `a` and `b` to `c` fold onto one pair of types in four kinds.
	 */
	private static function compared(): CodeGraph {
		final graph: CodeGraph = new CodeGraph();
		final px: String = graph.addNode(Package, 'p.x', 'p.x', null, false);
		final py: String = graph.addNode(Package, 'p.y', 'p.y', null, false);
		final x: String = graph.addNode(Type, 'p.x.X', 'X', px, false);
		final y: String = graph.addNode(Type, 'p.y.Y', 'Y', py, false);
		final z: String = graph.addNode(Type, 'p.y.Z', 'Z', py, false);
		final a: String = graph.addNode(Member, 'p.x.X.a', 'a', x, false);
		final b: String = graph.addNode(Member, 'p.x.X.b', 'b', x, false);
		final c: String = graph.addNode(Member, 'p.y.Y.c', 'c', y, false);
		final e: String = graph.addNode(Member, 'p.y.Z.e', 'e', z, false);
		mark(graph, z, Added);
		mark(graph, e, Added);
		mark(graph, a, Changed);
		mark(graph, b, Removed);
		edge(graph, a, c, Call, 3, Changed, 1);
		edge(graph, b, c, Call, 1, Removed, null);
		edge(graph, a, c, New, 1, Added, null);
		edge(graph, b, c, New, 1, Added, null);
		edge(graph, b, c, Ref, 1, Removed, null);
		edge(graph, a, c, Virtual, 1, Added, null);
		edge(graph, b, c, Virtual, 1, Removed, null);
		return graph;
	}

	private static function mark(graph: CodeGraph, id: String, change: GraphChange): Void {
		final n: Null<GraphNode> = graph.node(id);
		if (n != null) n.change = change;
	}

	private static function edge(
		graph: CodeGraph, from: String, to: String, kind: GraphEdgeKind, weight: Int, change: GraphChange, before: Null<Int>
	): Void {
		graph.addEdge(from, to, kind, weight);
		final e: Null<GraphEdge> = graph.edge(from, to, kind);
		if (e == null) return;
		e.change = change;
		if (before != null) e.before = before;
	}

	/** Each node of `graph` by name and the sign of its change, `=` for none. */
	private static function changes(graph: CodeGraph): String {
		return [for (n in graph.nodes()) '${n.name} ${signOf(n.change)}'].join('|');
	}

	private static function signOf(change: Null<GraphChange>): String {
		return change == null ? '=' : change.sign();
	}

	/** Each edge of `graph` by its ends' names, kind and weight, then its change or `-`, then any earlier weight. */
	private static function edges(graph: CodeGraph): String {
		final out: Array<String> = [];
		for (e in graph.edges()) {
			final change: Null<GraphChange> = e.change;
			final before: Null<Int> = e.before;
			final was: String = before == null ? '' : ' was $before';
			final how: String = change ?? '-';
			out.push('${graph.node(e.from)?.name} -> ${graph.node(e.to)?.name} ${e.kind} ${e.weight} $how$was');
		}
		return out.join('|');
	}

}
