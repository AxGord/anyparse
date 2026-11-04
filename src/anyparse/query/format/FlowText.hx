package anyparse.query.format;

import anyparse.query.graph.FlowGraph;

/**
 * A `FlowGraph` as a text report: a count line, the nodes in reading order (id, kind, line, text), then the edges.
 * A folded run keeps one statement per continuation line.
 */
@:nullSafety(Strict)
final class FlowText {

	/** The report of `graph`, every line ending in a line break. */
	public static function write(graph: FlowGraph): String {
		final nodes: Array<FlowNode> = graph.nodes();
		final edges: Array<FlowEdge> = graph.edges();
		final out: StringBuf = new StringBuf();
		out.add('${graph.name}: ${nodes.length} node(s), ${edges.length} edge(s)\n');
		out.add('nodes:\n');
		for (n in nodes) {
			final lines: Array<String> = n.label.split('\n');
			out.add('  ${n.id}  ${n.kind}  line ${n.line}  ${lines[0]}\n');
			for (rest in lines.slice(1)) out.add('    $rest\n');
		}
		out.add('edges:\n');
		for (e in edges) {
			final label: Null<String> = e.label;
			out.add('  ${e.from} -> ${e.to}${label == null ? '' : '  $label'}\n');
		}
		return out.toString();
	}

}
