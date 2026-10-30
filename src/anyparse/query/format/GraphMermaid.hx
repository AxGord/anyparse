package anyparse.query.format;

import anyparse.grammar.mermaid.MermaidFormat;
import anyparse.grammar.mermaid.MermaidWriter;
import anyparse.grammar.mermaid.MmdFlowchart;
import anyparse.grammar.mermaid.MmdLabel;
import anyparse.grammar.mermaid.MmdLinkLit;
import anyparse.grammar.mermaid.MmdNode;
import anyparse.grammar.mermaid.MmdNodeGroup;
import anyparse.grammar.mermaid.MmdStatement;
import anyparse.query.graph.CodeGraph;

/**
 * A `CodeGraph` as a Mermaid flowchart, built as the Mermaid grammar's AST and written by its writer:
 * a node that holds others is a subgraph, any other a vertex shaped by its level, and the edges follow
 * at the top level, labelled by kind (a call or an import is unlabelled) and
 * by weight above one; an edge whose ends depend on each other is drawn red.
 *
 * Every label is `MmdLabel.Plain`, the text a reader sees, so the label codec escapes whatever Mermaid
 * would read as syntax or markup — a type label `Map<String, Int>` renders as written.
 */
@:nullSafety(Strict)
final class GraphMermaid {

	/** The class a focused node carries, and its style. */
	private static inline final FOCUS_CLASS: String = 'focus';

	private static inline final FOCUS_STYLE: String = 'stroke-width:3px';

	/** The class an external node carries, and its style. */
	private static inline final EXTERNAL_CLASS: String = 'external';

	private static inline final EXTERNAL_STYLE: String = 'stroke-dasharray:4 3';

	/** The style of an edge whose ends depend on each other (`CodeGraph.isMutual`). */
	private static inline final MUTUAL_STYLE: String = 'stroke:#d33,stroke-width:2px';

	/** The flowchart of `graph`, after a `%%` comment line holding `caption` when one is given. */
	public static function flowchart(graph: CodeGraph, ?caption: String): MmdFlowchart {
		final statements: Array<MmdStatement> = [];
		if (caption != null) statements.push(Comment('%% ${caption.replace('\r', ' ').replace('\n', ' ')}'));
		statements.push(Header(Flowchart(LR)));
		final byParent: Map<String, Array<GraphNode>> = graph.nodesByParent();
		for (n in byParent[''] ?? []) statements.push(declaration(byParent, n));
		final edges: Array<GraphEdge> = graph.edges();
		for (e in edges) statements.push(Chain({
			head: group(Id(e.from)),
			links: [
				{ edge: Arrow({ link: linkOf(e.kind), label: edgeLabel(e) }), target: group(Id(e.to)) }
			]
		}));
		final leaves: Array<GraphNode> = graph.nodes().filter(n -> !byParent.exists(n.id));
		classed(statements, FOCUS_CLASS, FOCUS_STYLE, leaves.filter(n -> n.focus));
		classed(statements, EXTERNAL_CLASS, EXTERNAL_STYLE, leaves.filter(n -> n.external));
		// a link's ordinal is its place among the chart's links, and every edge is one chain of one link
		final mutual: Array<String> = [for (i => e in edges) if (graph.isMutual(e)) '$i'];
		if (mutual.length > 0) statements.push(LinkStyle({ links: mutual.join(','), curve: null, styles: MUTUAL_STYLE }));
		return { first: statements[0], rest: statements.slice(1) };
	}

	/** The flowchart of `graph` as Mermaid text. */
	public static function write(graph: CodeGraph, ?caption: String): String {
		return MermaidWriter.write(flowchart(graph, caption), MermaidFormat.instance.defaultWriteOptions);
	}

	private static inline function group(vertex: MmdNode): MmdNodeGroup {
		return { vertex: vertex, also: [] };
	}

	/** The statement declaring `n`: a subgraph of the nodes it holds (`byParent`), or a vertex. */
	private static function declaration(byParent: Map<String, Array<GraphNode>>, n: GraphNode): MmdStatement {
		final children: Null<Array<GraphNode>> = byParent[n.id];
		return children == null
			? Chain({ head: group(vertex(n)), links: [] })
			: Subgraph({ head: Titled({ name: n.id, title: Plain(n.label) }), body: [for (c in children) declaration(byParent, c)] });
	}

	/** `n` as a vertex: a member rounded, a type a subroutine box, a package or group a rectangle, an external node a stadium. */
	private static function vertex(n: GraphNode): MmdNode {
		final id: MmdNode = Id(n.id);
		final label: MmdLabel = Plain(n.label);
		if (n.external) return Stadium(id, label);
		return switch n.level {
			case Member: Round(id, label);
			case Type: Subroutine(id, label);
			case Package, Group: Rect(id, label);
		};
	}

	private static function linkOf(kind: GraphEdgeKind): MmdLinkLit {
		return switch kind {
			case Call, Accessor, Import: '-->';
			case New: '==>';
			case Ref, Virtual: '-.->';
			case Contains: '--o';
		};
	}

	/** The kind unless it is a call or an import, then the weight when above one; null when both are left out. */
	private static function edgeLabel(e: GraphEdge): Null<MmdLabel> {
		final parts: Array<String> = [];
		if (e.kind != Call && e.kind != Import) parts.push(e.kind);
		if (e.weight > 1) parts.push('${e.weight}');
		return parts.length == 0 ? null : Plain(parts.join(' '));
	}

	/** A `classDef` and a `class` statement giving `nodes` the class `name`, when there are any. */
	private static function classed(statements: Array<MmdStatement>, name: String, style: String, nodes: Array<GraphNode>): Void {
		if (nodes.length == 0) return;
		statements.push(ClassDef({ names: name, styles: style }));
		statements.push(Class({ nodes: [for (n in nodes) n.id].join(','), className: name }));
	}

}
