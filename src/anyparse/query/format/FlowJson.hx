package anyparse.query.format;

import anyparse.grammar.json.JsonFormat;
import anyparse.query.format.json.FlowChartJson;
import anyparse.query.format.json.FlowChartJsonWriter;
import anyparse.query.format.json.FlowEdgeJson;
import anyparse.query.format.json.FlowNodeJson;
import anyparse.query.graph.FlowGraph;

/** A `FlowGraph` as JSON: the `FlowChartJson` schema type, written by its generated writer. */
@:nullSafety(Strict)
final class FlowJson {

	/** The schema value of `graph`, nodes and edges in the graph's order. */
	public static function document(graph: FlowGraph): FlowChartJson {
		return {
			name: graph.name,
			nodes: graph.nodes().map(n -> ({
				id: n.id,
				kind: n.kind,
				label: n.label,
				line: n.line
			}: FlowNodeJson)),
			edges: [
				for (e in graph.edges()) {
					final edge: FlowEdgeJson = { from: e.from, to: e.to };
					if (e.label != null) edge.label = e.label;
					edge;
				}
			]
		};
	}

	/** `graph` as JSON text, one trailing line break. */
	public static function write(graph: FlowGraph): String {
		return '${FlowChartJsonWriter.write(document(graph), JsonFormat.instance.defaultWriteOptions)}\n';
	}

}
