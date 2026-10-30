package anyparse.query.format;

import anyparse.grammar.mermaid.MermaidFormat;
import anyparse.grammar.mermaid.MermaidWriter;
import anyparse.grammar.mermaid.MmdDirection;
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
 * by weight above one; an edge whose ends depend on each other is drawn red. A graph comparing two versions
 * (`GraphDiff`) colours each added, removed or changed vertex and link, a changed link closing a cycle thick in its
 * change's colour, and signs a changed subgraph's title.
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

	/** The width a changed edge whose ends depend on each other is drawn at, in its change's colour. */
	private static inline final MUTUAL_CHANGED_WIDTH: String = 'stroke-width:4px';

	/**
	 * The styles of a node, and of a link, a graph comparing two versions
	 * marks added, removed or changed; the class is the change's name.
	 */
	private static inline final ADDED_NODE_STYLE: String = 'fill:#dfd,stroke:#2a2';

	private static inline final REMOVED_NODE_STYLE: String = 'fill:#eee,stroke:#999,stroke-dasharray:4 3';
	private static inline final CHANGED_NODE_STYLE: String = 'fill:#ffd,stroke:#d90';
	private static inline final ADDED_LINK_STYLE: String = 'stroke:#2a2,stroke-width:2px';
	private static inline final REMOVED_LINK_STYLE: String = 'stroke:#999,stroke-dasharray:4 3';
	private static inline final CHANGED_LINK_STYLE: String = 'stroke:#d90,stroke-width:2px';

	/**
	 * The flowchart of `graph` laid out toward `direction`, left to right when none, after a `%%` comment line holding
	 * `caption` when one is given.
	 */
	public static function flowchart(graph: CodeGraph, ?caption: String, ?direction: MmdDirection): MmdFlowchart {
		final statements: Array<MmdStatement> = [];
		if (caption != null) statements.push(Comment('%% ${caption.replace('\r', ' ').replace('\n', ' ')}'));
		statements.push(Header(Flowchart(direction ?? LR)));
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
		final changes: Array<GraphChange> = [Added, Removed, Changed];
		for (change in changes) classed(statements, change, nodeStyle(change), leaves.filter(n -> n.change == change));
		// a link's ordinal is its place among the chart's links, and every edge is one chain of one link
		final mutual: Array<Bool> = [for (e in edges) graph.isMutual(e)];
		for (change in changes) {
			linkStyled(statements, [for (i => e in edges) if (e.change == change && !mutual[i]) '$i'], linkStyle(change));
		}
		// a changed link closing a cycle keeps its change's colour, which a comparison exists to show, and is drawn thick
		for (change in changes) {
			linkStyled(
				statements, [for (i => e in edges) if (e.change == change && mutual[i]) '$i'], '${linkStyle(change)},$MUTUAL_CHANGED_WIDTH'
			);
		}
		linkStyled(statements, [for (i => e in edges) if (e.change == null && mutual[i]) '$i'], MUTUAL_STYLE);
		return { first: statements[0], rest: statements.slice(1) };
	}

	/** The flowchart of `graph` as Mermaid text. */
	public static function write(graph: CodeGraph, ?caption: String, ?direction: MmdDirection): String {
		return MermaidWriter.write(flowchart(graph, caption, direction), MermaidFormat.instance.defaultWriteOptions);
	}

	private static inline function group(vertex: MmdNode): MmdNodeGroup {
		return { vertex: vertex, also: [] };
	}

	/** The statement declaring `n`: a subgraph of the nodes it holds (`byParent`), or a vertex. */
	private static function declaration(byParent: Map<String, Array<GraphNode>>, n: GraphNode): MmdStatement {
		final children: Null<Array<GraphNode>> = byParent[n.id];
		return children == null
			? Chain({ head: group(vertex(n)), links: [] })
			: Subgraph({ head: Titled({ name: n.id, title: Plain(titleOf(n)) }), body: [for (c in children) declaration(byParent, c)] });
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
		if (e.change == Changed) parts.push('was ${e.before}');
		return parts.length == 0 ? null : Plain(parts.join(' '));
	}

	/** A `linkStyle` statement giving the links of ordinals `links` the style `styles`, when there are any. */
	private static function linkStyled(statements: Array<MmdStatement>, links: Array<String>, styles: String): Void {
		if (links.length > 0) statements.push(LinkStyle({ links: links.join(','), curve: null, styles: styles }));
	}

	/** A subgraph's title: its label, after the sign of its change in a graph comparing two versions, whose colours mark a vertex alone. */
	private static function titleOf(n: GraphNode): String {
		final change: Null<GraphChange> = n.change;
		return change == null ? n.label : '${change.sign()} ${n.label}';
	}

	private static function nodeStyle(change: GraphChange): String {
		return switch change {
			case Added: ADDED_NODE_STYLE;
			case Removed: REMOVED_NODE_STYLE;
			case Changed: CHANGED_NODE_STYLE;
		};
	}

	private static function linkStyle(change: GraphChange): String {
		return switch change {
			case Added: ADDED_LINK_STYLE;
			case Removed: REMOVED_LINK_STYLE;
			case Changed: CHANGED_LINK_STYLE;
		};
	}

	/** A `classDef` and a `class` statement giving `nodes` the class `name`, when there are any. */
	private static function classed(statements: Array<MmdStatement>, name: String, style: String, nodes: Array<GraphNode>): Void {
		if (nodes.length == 0) return;
		statements.push(ClassDef({ names: name, styles: style }));
		statements.push(Class({ nodes: [for (n in nodes) n.id].join(','), className: name }));
	}

}
