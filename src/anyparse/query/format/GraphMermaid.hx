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
 * at the top level, labelled by kind (a call or an import is unlabelled) and by weight above one.
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

	/** The flowchart of `graph`, after a `%%` comment line holding `caption` when one is given. */
	public static function flowchart(graph: CodeGraph, ?caption: String): MmdFlowchart {
		final statements: Array<MmdStatement> = [];
		if (caption != null) statements.push(Comment('%% ${caption.replace('\r', ' ').replace('\n', ' ')}'));
		statements.push(Header(Flowchart(LR)));
		for (n in graph.childrenOf(null)) statements.push(declaration(graph, n));
		for (e in graph.edges()) statements.push(Chain({
			head: group(Id(e.from)),
			links: [
				{ edge: Arrow({ link: linkOf(e.kind), label: edgeLabel(e) }), target: group(Id(e.to)) }
			]
		}));
		final leaves: Array<GraphNode> = graph.nodes().filter(n -> graph.childrenOf(n.id).length == 0);
		classed(statements, FOCUS_CLASS, FOCUS_STYLE, leaves.filter(n -> n.focus));
		classed(statements, EXTERNAL_CLASS, EXTERNAL_STYLE, leaves.filter(n -> n.external));
		return { first: statements[0], rest: statements.slice(1) };
	}

	/** The flowchart of `graph` as Mermaid text. */
	public static function write(graph: CodeGraph, ?caption: String): String {
		return MermaidWriter.write(flowchart(graph, caption), MermaidFormat.instance.defaultWriteOptions);
	}

	private static inline function group(vertex: MmdNode): MmdNodeGroup {
		return { vertex: vertex, also: [] };
	}

	/** The statement declaring `n`: a subgraph of its children, or a vertex. */
	private static function declaration(graph: CodeGraph, n: GraphNode): MmdStatement {
		final children: Array<GraphNode> = graph.childrenOf(n.id);
		return children.length == 0
			? Chain({ head: group(vertex(n)), links: [] })
			: Subgraph({ head: Titled({ name: n.id, title: Plain(n.label) }), body: [for (c in children) declaration(graph, c)] });
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
