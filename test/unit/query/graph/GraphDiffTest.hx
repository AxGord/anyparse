package unit.query.graph;

import anyparse.query.CallGraph;
import anyparse.query.format.GraphText;
import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.GraphDiff;
import anyparse.query.graph.MemberGraphBuilder;

/**
 * `GraphDiff` — two member graphs of one scope compared: a member added, removed or changed by the caller's word, a
 * type added, an edge added, removed or reweighted; an unchanged member folded into its type, and an edge between
 * unchanged nodes left out.
 */
@:nullSafety(Strict)
class GraphDiffTest extends Test {

	/** The whole comparison as the text report reads it. */
	public function testTheReportMarksEveryChange(): Void {
		Assert.equals(GraphFixture.DIFF_REPORT, GraphText.write(compared()));
	}

	/** A member no change names folds into its type, which keeps its edges; a changed member stands on its own. */
	@:killer('M-GRAPH-DIFF-UNCHANGED-UNFOLDED')
	@:pin('control')
	public function testAnUnchangedMemberFoldsIntoItsType(): Void {
		final diff: CodeGraph = compared();
		Assert.isNull(diff.node(CodeGraph.idOf(Member, 'p.A.step')), 'an unchanged member is no node of its own');
		Assert.equals(CodeGraph.idOf(Type, 'p.A'), diff.node(CodeGraph.idOf(Member, 'p.A.run'))?.parent);
		Assert.equals(Changed, diff.node(CodeGraph.idOf(Member, 'p.A.run'))?.change);
		Assert.isNull(diff.node(CodeGraph.idOf(Type, 'p.A'))?.change, 'a type both versions hold is no change of its own');
	}

	/** An edge both versions hold at another weight is changed, its earlier weight kept beside the later one. */
	@:killer('M-GRAPH-DIFF-WEIGHT-IGNORED')
	@:pin('control')
	public function testAReweightedEdgeIsChanged(): Void {
		final e: Null<GraphEdge> = compared().edge(CodeGraph.idOf(Member, 'p.A.run'), CodeGraph.idOf(Type, 'p.A'), Call);
		Assert.equals(Changed, e?.change);
		Assert.equals(2, e?.weight);
		Assert.equals(3, e?.before);
	}

	/** An edge between two unchanged nodes is no part of the change; one touching a changed member is, unmarked. */
	@:killer('M-GRAPH-DIFF-UNCHANGED-EDGE-KEPT')
	@:pin('control')
	public function testAnEdgeBetweenUnchangedNodesIsLeftOut(): Void {
		final diff: CodeGraph = compared();
		Assert.isNull(diff.edge(CodeGraph.idOf(Type, 'p.B'), CodeGraph.idOf(Type, 'p.A'), New), 'B builds an A in both versions');
		Assert.isNull(diff.edge(CodeGraph.idOf(Type, 'p.B'), CodeGraph.idOf(Member, 'p.A.run'), Call)?.change);
		Assert.notNull(diff.edge(CodeGraph.idOf(Type, 'p.B'), CodeGraph.idOf(Member, 'p.A.run'), Call));
	}

	/**
	 * A dependency inverted — removed one way, added the other — is no cycle: no version holds both ways. A way back
	 * added beside a way both versions hold is one, of the later version.
	 */
	@:killer('M-GRAPH-DIFF-INVERSION-AS-CYCLE')
	@:pin('control')
	public function testAnInvertedDependencyIsNoCycle(): Void {
		final one: String =
			'package p;\nclass A { public function run():Void { B.go(); } }\nclass B { public static function go():Void {} }\n';
		final inverted: String =
			'package p;\nclass A { public function run():Void {} }\nclass B { public static function go():Void { new A().run(); } }\n';
		final both: String = 'package p;\nclass A { public function run():Void { B.go(); } }\n'
			+ 'class B { public static function go():Void { new A().run(); } }\n';
		final flipped: CodeGraph = GraphDiff.compare(declared(one), declared(inverted), ['p.A.run', 'p.B.go']);
		Assert.equals(0, flipped.edges().filter(flipped.isMutual).length, GraphText.write(flipped));
		final closed: CodeGraph = GraphDiff.compare(declared(one), declared(both), ['p.B.go']);
		Assert.isTrue(GraphText.write(closed).indexOf('1 mutual pair(s)') >= 0, GraphText.write(closed));
	}

	/** Two equal versions compare to an empty graph. */
	public function testEqualVersionsCompareEmpty(): Void {
		final diff: CodeGraph = GraphDiff.compare(declared(GraphFixture.DIFF_BEFORE), declared(GraphFixture.DIFF_BEFORE), []);
		Assert.equals(0, diff.nodes().length);
		Assert.equals(0, diff.edges().length);
	}

	/** `MemberGraphBuilder.declared` holds a member no edge reaches. */
	public function testDeclaredHoldsAMemberWithNoEdge(): Void {
		Assert.notNull(declared(GraphFixture.DIFF_BEFORE).node(CodeGraph.idOf(Member, 'p.B.idle')));
	}

	/** `BEFORE` against `AFTER`, `run` named as changed. */
	private static function compared(): CodeGraph {
		return GraphDiff.compare(declared(GraphFixture.DIFF_BEFORE), declared(GraphFixture.DIFF_AFTER), ['p.A.run']);
	}

	private static function declared(source: String): CodeGraph {
		return MemberGraphBuilder.declared(CallGraph.build([{ file: 'p/A.hx', source: source }], new HaxeQueryPlugin()), null);
	}

}
