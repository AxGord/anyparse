package unit.query.graph;

import anyparse.query.CallGraph;
import anyparse.query.Clusters;
import anyparse.query.Reach;
import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.MemberGraphBuilder;

/**
 * `MemberGraphBuilder` — the call graph lifted to members: a lambda folded into the member declaring
 * it, sites of one kind between two members counted as one edge, each member nested in its type and the
 * type in its package, the nodes a query asked about focused.
 */
@:nullSafety(Strict)
class MemberGraphBuilderTest extends Test {

	/** `callees` walks out-edges; the lambda in `step` is no node, its call is `step`'s; two calls are one edge of weight 2. */
	@:killer('M-GRAPH-LAMBDA-UNFOLDED')
	@:pin('control')
	public function testChainsFoldLambdasIntoTheirMember(): Void {
		final graph: CodeGraph = MemberGraphBuilder.chains(GraphFixture.calls(), ['Alpha.run'], 3, true, null);
		Assert.equals('', [for (n in graph.nodes()) if (n.name.indexOf('#') >= 0) n.name].join(','), 'no lambda node');
		Assert.isTrue(edges(graph).contains('pkg.a.Alpha.step -call-> pkg.b.Beta.make x1'));
		Assert.isTrue(edges(graph).contains('pkg.a.Alpha.run -call-> pkg.a.Alpha.step x2'));
		Assert.equals('pkg.a.Alpha.run', [for (n in graph.nodes()) if (n.focus) n.name].join(','));
	}

	/** Each member sits in its type and the type in its package; an edge inside a member is dropped, its lambda's call is its own. */
	public function testMembersNestInTypeAndPackage(): Void {
		final graph: CodeGraph = MemberGraphBuilder.chains(GraphFixture.calls(), ['Alpha.step'], 1, true, null);
		final step: Null<GraphNode> = graph.node(CodeGraph.idOf(Member, 'pkg.a.Alpha.step'));
		Assert.equals(CodeGraph.idOf(Type, 'pkg.a.Alpha'), step?.parent);
		Assert.equals(CodeGraph.idOf(Package, 'pkg.a'), graph.node(step?.parent ?? '')?.parent);
		Assert.equals('pkg.a.Alpha.step -call-> pkg.b.Beta.make x1', edges(graph).join('|'));
	}

	/** `callers` walks in-edges to the depth asked. */
	public function testChainsInwardWalkCallers(): Void {
		final graph: CodeGraph = MemberGraphBuilder.chains(GraphFixture.calls(), ['Gamma.tick'], 2, false, null);
		Assert.equals('pkg.a.Alpha.run -call-> pkg.b.Beta.work x1|pkg.b.Beta.work -call-> pkg.b.Gamma.tick x1', edges(graph).join('|'));
	}

	/** A function calling itself keeps its loop: recursion, not a member's inside. */
	public function testRecursionKeepsItsLoop(): Void {
		final calls: CallGraph = CallGraph.build([{ file: 'R.hx', source: 'class R { function f():Void f(); }' }], new HaxeQueryPlugin());
		Assert.equals('R.f -call-> R.f x1', edges(MemberGraphBuilder.chains(calls, ['R.f'], 1, true, null)).join('|'));
	}

	/** A local function calling itself stays inside its member: no loop on the member that declares it. */
	@:killer('M-GRAPH-LOCAL-RECURSION-DRAWN')
	@:pin('control')
	public function testALocalFunctionsRecursionDrawsNoLoop(): Void {
		Assert.equals(
			'Foo.outer -call-> Bar.deep x1|Foo.outer -call-> Bar.inner x1',
			edges(MemberGraphBuilder.chains(nested(), ['Foo.outer'], 1, true, null)).join('|')
		);
	}

	/** One hop from a member reaches what its lambdas and local functions call: folding into the member costs no hop. */
	@:killer('M-GRAPH-DEPTH-SPENT-ON-LOCALS')
	@:pin('control')
	public function testAHopOutwardCrossesTheMembersLocals(): Void {
		Assert.equals(
			'Foo.outer -call-> Bar.deep x1|Foo.outer -call-> Bar.inner x1',
			edges(MemberGraphBuilder.chains(nested(), ['Foo.outer'], 1, true, [Call])).join('|')
		);
	}

	/** One hop inward from a callee reaches the member whose lambda calls it, and the next hop that member's callers. */
	@:killer('M-GRAPH-CALLER-HOP-ON-LOCALS')
	@:pin('control')
	public function testAHopInwardCrossesTheCallersLocals(): Void {
		Assert.equals(
			'Foo.outer -call-> Bar.inner x1|Foo.top -call-> Foo.outer x1',
			edges(MemberGraphBuilder.chains(nested(), ['Bar.inner'], 2, false, [Call])).join('|')
		);
	}

	/** `reach` draws the edges of each path found and focuses both ends. */
	public function testPathsFocusBothEnds(): Void {
		final calls: CallGraph = GraphFixture.calls();
		final graph: CodeGraph = MemberGraphBuilder.paths(calls, Reach.paths(calls, ['Alpha.run'], ['Gamma.tick'], 10, [Call]));
		Assert.equals('pkg.a.Alpha.run -call-> pkg.b.Beta.work x1|pkg.b.Beta.work -call-> pkg.b.Gamma.tick x1', edges(graph).join('|'));
		Assert.equals('pkg.a.Alpha.run,pkg.b.Gamma.tick', [for (n in graph.nodes()) if (n.focus) n.name].join(','));
	}

	/** `clusters` groups the members by component under their type, with the hubs in a group of their own. */
	public function testClustersGroupByComponent(): Void {
		final calls: CallGraph = CallGraph.build([
			{
				file: 'A.hx',
				source: 'class A { function a():Void { b(); log(); } function b():Void log(); function c():Void { d(); log(); }'
				+ ' function d():Void log(); function log():Void {} }'
			}
		], new HaxeQueryPlugin());
		final report: Null<ClusterReport> = Clusters.analyze(calls, 'A', null, null);
		if (report == null) {
			Assert.fail('no report');
			return;
		}
		final graph: CodeGraph = MemberGraphBuilder.clusters(calls, report);
		final byParent: Map<String, Array<GraphNode>> = graph.nodesByParent();
		final groups: Array<String> = [
			for (g in graph.nodes()) if (g.level == Group) '${g.label}: ${[for (n in byParent[g.id] ?? []) n.label].join(',')}'
		];
		Assert.equals('component 1: a,b|component 2: c,d|hubs: log', groups.join('|'));
		Assert.isTrue(edges(graph).contains('A.a -call-> A.log x1'));
	}

	/** Every edge as `from -kind-> to xweight`, by the nodes' names. */
	private static function edges(graph: CodeGraph): Array<String> {
		return [
			for (e in graph.edges()) '${graph.node(e.from)?.name} -${e.kind}-> ${graph.node(e.to)?.name} x${e.weight}'
		];
	}

	/** `Foo.outer` calls `Bar.inner` from a lambda and `Bar.deep` from a recursive local function; `Foo.top` calls `outer`. */
	private static function nested(): CallGraph {
		return CallGraph.build([
			{
				file: 'Foo.hx',
				source: 'class Foo { function top():Void outer(); function outer():Void { final f:() -> Void = () -> Bar.inner(); f();'
				+ ' function loop(n:Int):Void { if (n > 0) loop(n - 1); Bar.deep(); } loop(3); } }'
			},
			{ file: 'Bar.hx', source: 'class Bar { public static function inner():Void {} public static function deep():Void {} }' }
		], new HaxeQueryPlugin());
	}

}
