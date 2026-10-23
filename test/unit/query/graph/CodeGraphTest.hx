package unit.query.graph;

import anyparse.grammar.mermaid.MermaidParser;
import anyparse.grammar.mermaid.MmdStatement;
import anyparse.query.graph.CodeGraph;
import unit.grammar.MermaidAst;

/**
 * `CodeGraph` — node ids derived from level and name alone, each a Mermaid node id as it stands and no
 * two alike; edges merged per (from, to, kind) with their sites counted; every listing ordered by id.
 */
@:nullSafety(Strict)
class CodeGraphTest extends Test {

	/** Names that differ only where an escape could merge them, or that Mermaid would read as syntax. */
	private static final NAMES: Array<String> = [
		'a.b',
		'a_b',
		'a._b',
		'a_.b',
		'a_d',
		'a.',
		'a__',
		'end',
		'subgraph',
		'Type.<init>',
		'Mod.f@2',
		'Type.m#1',
		'a b',
		'a_x41_',
		'aA',
		'ünï',
		'Map<String, Int>'
	];

	/** Every id is letters, digits and `_`, parses as a bare Mermaid node, and no two names share one. */
	@:killer('M-GRAPH-ID-UNDERSCORE-BARE')
	@:pin('control')
	public function testIdsAreMermaidIdsAndInjective(): Void {
		final owner: Map<String, String> = [];
		for (name in NAMES) {
			final id: String = CodeGraph.idOf(Member, name);
			Assert.isTrue(~/^[A-Za-z0-9_]+$/.match(id), id);
			Assert.isFalse(owner.exists(id), '"${owner[id]}" and "$name" share an id');
			owner[id] = name;
			final bare: MmdStatement = Chain({ head: { vertex: Id(id), also: [] }, links: [] });
			Assert.equals(MermaidAst.dump([bare]), MermaidAst.dump(MermaidParser.parse('flowchart LR\n$id\n').rest), id);
		}
	}

	/** The level is part of the id: a package and a type of one name are two nodes. */
	public function testTheLevelKeepsNamesApart(): Void {
		final graph: CodeGraph = new CodeGraph();
		final pkg: String = graph.addNode(Package, 'a', 'a', null, false);
		final type: String = graph.addNode(Type, 'a', 'a', pkg, false);
		Assert.notEquals(pkg, type);
		Assert.equals(2, graph.nodes().length);
		Assert.equals(pkg, graph.addNode(Package, 'a', 'other label', null, true), 'a node is added once');
		Assert.equals('a', graph.node(pkg)?.label);
	}

	/** Edges of one kind between one pair merge and count their sites; other kinds stay apart; the order is by id. */
	public function testEdgesMergeByKindAndCountSites(): Void {
		final graph: CodeGraph = new CodeGraph();
		final b: String = graph.addNode(Member, 'b', 'b', null, false);
		final a: String = graph.addNode(Member, 'a', 'a', null, false);
		graph.addEdge(b, a, Call);
		graph.addEdge(a, b, Call);
		graph.addEdge(a, b, Call, 2);
		graph.addEdge(a, b, Ref);
		final edges: Array<GraphEdge> = graph.edges();
		Assert.equals('m_a m_b call 3|m_a m_b ref 1|m_b m_a call 1', [for (e in edges) '${e.from} ${e.to} ${e.kind} ${e.weight}'].join(
			'|'
		));
		Assert.equals('m_a,m_b', [for (n in graph.nodes()) n.id].join(','));
	}

	/** An edge or a parent naming no node is a bug in the builder, not a node to invent. */
	public function testUnknownEndsAreRefused(): Void {
		final graph: CodeGraph = new CodeGraph();
		final a: String = graph.addNode(Member, 'a', 'a', null, false);
		Assert.raises(() -> graph.addEdge(a, 'm_nowhere', Call), Exception);
		Assert.raises(() -> graph.addNode(Member, 'b', 'b', 'p_nowhere', false), Exception);
		Assert.raises(graph.markFocus.bind('m_nowhere'), Exception);
	}

}
