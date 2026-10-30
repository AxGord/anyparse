package anyparse.query.format;

import anyparse.query.graph.CodeGraph;
import haxe.ds.ArraySort;

/**
 * A `CodeGraph` as a text report: a count line, then the pairs of nodes that depend on each other with the weight
 * each way, then every edge heaviest first. A node reads as its qualified name, an external one marked so.
 */
@:nullSafety(Strict)
final class GraphText {

	/** The report of `graph`, every line ending in a line break. */
	public static function write(graph: CodeGraph): String {
		final edges: Array<GraphEdge> = graph.edges();
		final pairs: Array<{ a: String, b: String }> = [];
		final seen: Map<String, Bool> = [];
		for (e in edges) if (e.from < e.to && graph.isMutual(e) && !seen.exists('${e.from} ${e.to}')) {
			seen['${e.from} ${e.to}'] = true;
			pairs.push({ a: e.from, b: e.to });
		}
		pairs.sort((x, y) -> {
			final heavier: Int = pairWeight(graph, y) - pairWeight(graph, x);
			return heavier != 0 ? heavier : compareText('${x.a} ${x.b}', '${y.a} ${y.b}');
		});
		final heaviest: Array<GraphEdge> = edges.copy();
		// a stable sort keeps the graph's own order among edges of one weight
		ArraySort.sort(heaviest, (x, y) -> y.weight - x.weight);
		final out: StringBuf = new StringBuf();
		out.add('${graph.nodes().length} node(s), ${edges.length} edge(s), ${pairs.length} mutual pair(s)\n');
		if (pairs.length > 0) {
			out.add('mutual:\n');
			for (p in pairs)
				out.add(
					'  ${display(graph, p.a)} <-> ${display(graph, p.b)}  ${graph.weightBetween(p.a, p.b)}/'
					+ '${graph.weightBetween(p.b, p.a)}\n'
				);
		}
		if (heaviest.length > 0) {
			out.add('edges:\n');
			for (e in heaviest) out.add('  ${display(graph, e.from)} -> ${display(graph, e.to)}  ${e.kind} ${e.weight}\n');
		}
		return out.toString();
	}

	private static inline function compareText(a: String, b: String): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

	private static function pairWeight(graph: CodeGraph, p: { a: String, b: String }): Int {
		return graph.weightBetween(p.a, p.b) + graph.weightBetween(p.b, p.a);
	}

	/** The node `id` as a reader names it: its qualified name, or its label when the name is empty (the root package). */
	private static function display(graph: CodeGraph, id: String): String {
		final n: Null<GraphNode> = graph.node(id);
		if (n == null) return id;
		final shown: String = n.name == '' ? n.label : n.name;
		return n.external ? '$shown [external]' : shown;
	}

}
