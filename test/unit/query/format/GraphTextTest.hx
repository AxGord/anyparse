package unit.query.format;

import anyparse.query.format.GraphText;
import anyparse.query.graph.CodeGraph;

/**
 * `GraphText` — the text report of a code graph: the counts, the pairs depending on each other with the weight each
 * way, heaviest first, then every edge heaviest first; the root package by its label, an external node marked.
 */
@:nullSafety(Strict)
class GraphTextTest extends Test {

	/**
	 * The pairs heaviest first, each weight in the order the pair is written; the edges heaviest first, ties in the graph order.
	 */
	public function testGolden(): Void {
		final graph: CodeGraph = new CodeGraph();
		final root: String = graph.addNode(Package, '', '(root)', null, false);
		final a: String = graph.addNode(Package, 'a', 'a', null, false);
		final b: String = graph.addNode(Package, 'b', 'b', null, false);
		final c: String = graph.addNode(Package, 'c', 'c', null, false);
		final ext: String = graph.addNode(Type, 'String', 'String', null, true);
		graph.addEdge(a, b, Import, 3);
		graph.addEdge(b, a, Import);
		graph.addEdge(c, root, Import, 2);
		graph.addEdge(root, c, Call, 7);
		graph.addEdge(a, ext, Ref);
		Assert.equals([
			'5 node(s), 5 edge(s), 2 mutual pair(s)',
			'mutual:',
			'  (root) <-> c  7/2',
			'  a <-> b  3/1',
			'edges:',
			'  (root) -> c  call 7',
			'  a -> b  import 3',
			'  c -> (root)  import 2',
			'  a -> String [external]  ref 1',
			'  b -> a  import 1',
			''
		].join('\n'), GraphText.write(graph));
	}

	/** A graph with no edge is its count line alone. */
	public function testAnEdgelessGraphIsItsCountLine(): Void {
		final graph: CodeGraph = new CodeGraph();
		Assert.equals('p_a', graph.addNode(Package, 'a', 'a', null, false));
		Assert.equals('1 node(s), 0 edge(s), 0 mutual pair(s)\n', GraphText.write(graph));
	}

}
