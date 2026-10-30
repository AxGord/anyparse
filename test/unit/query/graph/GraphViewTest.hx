package unit.query.graph;

import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.GraphView;

/**
 * `GraphView` — a code graph lifted to a coarser level, its packages folded to a depth, and pruned by weight, by a
 * focus and a radius, to mutual pairs, or to the scope: what each keeps, what it sums, and that the input is untouched.
 */
@:nullSafety(Strict)
class GraphViewTest extends Test {

	/** At the type level the members' edges count on their types, summed per kind; an edge inside one type is dropped. */
	public function testLiftSumsEdgesOnTheTypes(): Void {
		final graph: CodeGraph = members();
		// a type reaching its own member folds shut at the type level, not into the type's recursion
		graph.addEdge(CodeGraph.idOf(Type, 'p.a.A'), CodeGraph.idOf(Member, 'p.a.A.m2'), Ref);
		final lifted: CodeGraph = GraphView.lift(graph, Type);
		Assert.equals('p.a.A -> p.b.B call 3|p.a.A -> p.b.B new 1|p.b.B -> String ref 1', edges(lifted));
		Assert.equals('p.a.A', [for (n in lifted.nodes()) if (n.focus) n.name].join(','), 'a member focused focuses its type');
		Assert.equals('String,p.a,p.b,p.a.A,p.b.B', names(lifted));
	}

	/** At the package level an external type, which has no package, is left out with its edges. */
	public function testLiftLeavesOutWhatHasNoAncestorAtTheLevel(): Void {
		final lifted: CodeGraph = GraphView.lift(members(), Package);
		Assert.equals('p.a -> p.b call 3|p.a -> p.b new 1', edges(lifted));
		Assert.equals('p.a,p.b', names(lifted));
	}

	/** At its own level a node keeps its own recursion; lifting copies the graph and leaves the input as it was. */
	public function testLiftToTheSameLevelKeepsRecursion(): Void {
		final graph: CodeGraph = members();
		final before: String = edges(graph);
		Assert.equals(before, edges(GraphView.lift(graph, Member)));
		Assert.isTrue(before.indexOf('p.a.A.m1 -> p.a.A.m1 call 1') >= 0);
		Assert.equals(before, edges(members()));
	}

	/**
	 * Packages deeper than the depth fold into their ancestor: their edges
	 * sum there, and an edge between two packages folding into one is dropped.
	 */
	@:killer('M-GRAPH-VIEW-FOLDED-EDGE-AS-RECURSION')
	@:pin('control')
	public function testFoldPackagesSumsOnTheAncestor(): Void {
		final graph: CodeGraph = new CodeGraph();
		final xyz: String = graph.addNode(Package, 'x.y.z', 'x.y.z', null, false);
		final xyq: String = graph.addNode(Package, 'x.y.q', 'x.y.q', null, false);
		final xw: String = graph.addNode(Package, 'x.w', 'x.w', null, false);
		final xy: String = graph.addNode(Package, 'x.y', 'x.y', null, false);
		final t: String = graph.addNode(Type, 'x.y.z.T', 'T', xyz, false);
		graph.addEdge(xyz, xw, Import, 2);
		graph.addEdge(xyq, xw, Import);
		graph.addEdge(xyz, xyq, Import);
		graph.addEdge(xw, xw, Import);
		graph.addEdge(xy, xyz, Import);
		final folded: CodeGraph = GraphView.foldPackages(graph, 2);
		Assert.equals('x.w -> x.w import 1|x.y -> x.w import 3', edges(folded));
		Assert.equals('p_x_dy', folded.node(t)?.parent, 'a type of a folded package nests in the ancestor, keeping its id');
	}

	/** A weight floor drops a light pair, but never the light way back of a heavy pair: that back edge is the cycle. */
	@:killer('M-GRAPH-VIEW-BACK-EDGE-HIDDEN')
	@:pin('control')
	public function testMinWeightKeepsTheWayBackOfAHeavyPair(): Void {
		final graph: CodeGraph = chain();
		graph.addEdge(CodeGraph.idOf(Package, 'b'), CodeGraph.idOf(Package, 'a'), Import);
		graph.addEdge(CodeGraph.idOf(Package, 'a'), CodeGraph.idOf(Package, 'b'), Import, 4);
		final view: CodeGraph = GraphView.filter(graph, filter(5, [], false, false));
		Assert.equals('a -> b import 5|b -> a import 1', edges(view));
		Assert.equals('a,b', names(view), 'the nodes kept are the ends of the edges drawn');
	}

	/** Around a focus node the view keeps what lies within the radius, either way, and marks the focus. */
	public function testFocusKeepsTheRadiusAroundIt(): Void {
		final b: String = CodeGraph.idOf(Package, 'b');
		final one: CodeGraph = GraphView.filter(chain(), filter(1, [b], false, false, 1));
		Assert.equals('a -> b import 1|b -> c import 1', edges(one));
		Assert.equals('b', [for (n in one.nodes()) if (n.focus) n.name].join(','));
		final none: CodeGraph = GraphView.filter(chain(), filter(1, [b], false, false, 0));
		Assert.equals('', edges(none));
		Assert.equals('b', names(none), 'a focus node stays with no edge drawn');
		Assert.equals('a -> b import 1|b -> c import 1|c -> d import 1', edges(GraphView.filter(chain(), filter(1, [b], false, false, 2))));
	}

	/** Mutual-only keeps the pairs that depend on each other. */
	public function testMutualOnlyKeepsThePairs(): Void {
		final graph: CodeGraph = chain();
		graph.addEdge(CodeGraph.idOf(Package, 'c'), CodeGraph.idOf(Package, 'b'), Import);
		Assert.equals('b -> c import 1|c -> b import 1', edges(GraphView.filter(graph, filter(1, [], true, false))));
	}

	/** Without a filter the graph is copied whole, but a node outside the scope only when the filter keeps it. */
	public function testExternalNodesStayOnlyWhenAsked(): Void {
		final lifted: CodeGraph = GraphView.lift(members(), Type);
		Assert.equals('p.a.A -> p.b.B call 3|p.a.A -> p.b.B new 1', edges(GraphView.filter(lifted, filter(1, [], false, false))));
		Assert.equals('p.a,p.b,p.a.A,p.b.B', names(GraphView.filter(lifted, filter(1, [], false, false))));
		Assert.equals(edges(lifted), edges(GraphView.filter(lifted, filter(1, [], false, true))));
	}

	/** A name answers its exact node first, else every node whose name ends with it after a dot. */
	public function testNamedPrefersTheExactName(): Void {
		final graph: CodeGraph = members();
		Assert.equals('p.a.A.m1', [for (n in GraphView.named(graph, 'A.m1', Member)) n.name].join(','));
		Assert.equals('p.a', [for (n in GraphView.named(graph, 'p.a', Package)) n.name].join(','));
		Assert.equals('', [for (n in GraphView.named(graph, '1', Member)) n.name].join(','), 'a suffix counts after a dot only');
		Assert.equals('p.a.A.m1,p.a.A.m2', [
			for (n in GraphView.named(graph, 'm1', Member).concat(GraphView.named(graph, 'm2', Member))) n.name
		].join(','));
	}

	/** A name answers the nodes of the level asked only: the package a lift brings in above the types is never named at the type level. */
	@:killer('M-GRAPH-VIEW-NAMED-ANY-LEVEL')
	@:pin('control')
	public function testNamedKeepsToTheLevel(): Void {
		final lifted: CodeGraph = GraphView.lift(members(), Type);
		Assert.equals('', [for (n in GraphView.named(lifted, 'a', Type)) n.name].join(','));
		Assert.equals('p.a', [for (n in GraphView.named(lifted, 'a', Package)) n.name].join(','));
		Assert.equals('p.a.A', [for (n in GraphView.named(lifted, 'A', Type)) n.name].join(','));
	}

	/** A member graph over packages `p.a` and `p.b`: `A.m1` calls `A.m2`, itself and `B.n`, `B.n` reaches an external member. */
	private static function members(): CodeGraph {
		final graph: CodeGraph = new CodeGraph();
		final pa: String = graph.addNode(Package, 'p.a', 'p.a', null, false);
		final pb: String = graph.addNode(Package, 'p.b', 'p.b', null, false);
		final a: String = graph.addNode(Type, 'p.a.A', 'A', pa, false);
		final b: String = graph.addNode(Type, 'p.b.B', 'B', pb, false);
		final m1: String = graph.addNode(Member, 'p.a.A.m1', 'm1', a, false);
		final m2: String = graph.addNode(Member, 'p.a.A.m2', 'm2', a, false);
		final n: String = graph.addNode(Member, 'p.b.B.n', 'n', b, false);
		final str: String = graph.addNode(Type, 'String', 'String', null, true);
		final len: String = graph.addNode(Member, 'String.length', 'length', str, true);
		graph.addEdge(m1, m2, Call);
		graph.addEdge(m1, m1, Call);
		graph.addEdge(m1, n, Call, 2);
		graph.addEdge(m2, n, Call);
		graph.addEdge(m2, n, New);
		graph.addEdge(n, len, Ref);
		graph.markFocus(m1);
		return graph;
	}

	/** Four packages in a chain `a -> b -> c -> d`, one import each. */
	private static function chain(): CodeGraph {
		final graph: CodeGraph = new CodeGraph();
		final ids: Array<String> = [
			for (name in ['a', 'b', 'c', 'd']) graph.addNode(Package, name, name, null, false)
		];
		for (i in 1...ids.length) graph.addEdge(ids[i - 1], ids[i], Import);
		return graph;
	}

	private static function filter(minWeight: Int, focus: Array<String>, mutualOnly: Bool, external: Bool, radius: Int = 1): GraphFilter {
		return {
			minWeight: minWeight,
			focus: focus,
			radius: radius,
			mutualOnly: mutualOnly,
			external: external
		};
	}

	/** Every edge as `from -> to kind weight`, by the nodes' names. */
	private static function edges(graph: CodeGraph): String {
		return [
			for (e in graph.edges()) '${graph.node(e.from)?.name} -> ${graph.node(e.to)?.name} ${e.kind} ${e.weight}'
		].join('|');
	}

	private static function names(graph: CodeGraph): String {
		return [for (n in graph.nodes()) n.name].join(',');
	}

}
