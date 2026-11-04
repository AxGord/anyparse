package anyparse.query.format;

import anyparse.grammar.mermaid.MermaidFormat;
import anyparse.grammar.mermaid.MermaidWriter;
import anyparse.grammar.mermaid.MmdDirection;
import anyparse.grammar.mermaid.MmdFlowchart;
import anyparse.grammar.mermaid.MmdLabel;
import anyparse.grammar.mermaid.MmdNode;
import anyparse.grammar.mermaid.MmdNodeGroup;
import anyparse.grammar.mermaid.MmdStatement;
import anyparse.query.graph.FlowGraph;

/**
 * A `FlowGraph` as a Mermaid flowchart, built as the Mermaid grammar's AST and written by its writer: the start and the
 * end a stadium, a decision, a loop and a switch the shapes of a decision, a run of statements a box, a `throw` drawn red.
 * A label is `MmdLabel.Plain`, the text a reader sees, so the label codec escapes whatever Mermaid would read as syntax.
 */
@:nullSafety(Strict)
final class FlowMermaid {

	/** The class a `throw` node carries, and its style. */
	private static inline final THROW_CLASS: String = 'throw';

	private static inline final THROW_STYLE: String = 'stroke:#d33,stroke-width:2px';

	/**
	 * The flowchart of `graph` laid out toward `direction`, top to bottom
	 * when none, after a `%%` line holding `caption` when one is given.
	 */
	public static function flowchart(graph: FlowGraph, ?caption: String, ?direction: MmdDirection): MmdFlowchart {
		final statements: Array<MmdStatement> = [];
		if (caption != null) statements.push(Comment('%% ${caption.replace('\r', ' ').replace('\n', ' ')}'));
		statements.push(Header(Flowchart(direction ?? TB)));
		for (n in graph.nodes()) statements.push(Chain({ head: group(vertex(n)), links: [] }));
		for (e in graph.edges()) {
			final label: Null<String> = e.label;
			statements.push(Chain({
				head: group(Id(e.from)),
				links: [
					{ edge: Arrow({ link: '-->', label: label == null ? null : Plain(label) }), target: group(Id(e.to)) }
				]
			}));
		}
		final thrown: Array<String> = [for (n in graph.nodes()) if (n.kind == Throw) n.id];
		if (thrown.length > 0) {
			statements.push(ClassDef({ names: THROW_CLASS, styles: THROW_STYLE }));
			statements.push(Class({ nodes: thrown.join(','), className: THROW_CLASS }));
		}
		return { first: statements[0], rest: statements.slice(1) };
	}

	/** The flowchart of `graph` as Mermaid text. */
	public static function write(graph: FlowGraph, ?caption: String, ?direction: MmdDirection): String {
		return MermaidWriter.write(flowchart(graph, caption, direction), MermaidFormat.instance.defaultWriteOptions);
	}

	private static inline function group(vertex: MmdNode): MmdNodeGroup {
		return { vertex: vertex, also: [] };
	}

	/** `n` as a vertex shaped by what it is. */
	private static function vertex(n: FlowNode): MmdNode {
		final id: MmdNode = Id(n.id);
		final label: MmdLabel = Plain(n.label);
		return switch n.kind {
			case Start, End, Return, Throw: Stadium(id, label);
			case Decision, Switch: Diamond(id, label);
			case Loop, Try: Hexagon(id, label);
			case Catch, Break, Continue: Round(id, label);
			case Declarations, Steps: Rect(id, label);
		};
	}

}
