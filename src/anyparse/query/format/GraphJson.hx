package anyparse.query.format;

import anyparse.grammar.json.JsonFormat;
import anyparse.query.format.json.CodeGraphJson;
import anyparse.query.format.json.CodeGraphJsonWriter;
import anyparse.query.format.json.CodeGraphNodeJson;
import anyparse.query.graph.CodeGraph;

/** A `CodeGraph` as JSON: the `CodeGraphJson` schema type, written by its generated writer. */
@:nullSafety(Strict)
final class GraphJson {

	/** The schema value of `graph`, nodes and edges in the graph's order. */
	public static function document(graph: CodeGraph): CodeGraphJson {
		return {
			nodes: [
				for (n in graph.nodes()) {
					final node: CodeGraphNodeJson = {
						id: n.id,
						level: n.level,
						name: n.name,
						label: n.label,
						external: n.external,
						focus: n.focus
					};
					if (n.parent != null) node.parent = n.parent;
					node;
				}
			],
			edges: [
				for (e in graph.edges())
					{
						from: e.from,
						to: e.to,
						kind: e.kind,
						weight: e.weight
					}
			]
		};
	}

	/** `graph` as JSON text, one trailing line break. */
	public static function write(graph: CodeGraph): String {
		return '${CodeGraphJsonWriter.write(document(graph), JsonFormat.instance.defaultWriteOptions)}\n';
	}

}
