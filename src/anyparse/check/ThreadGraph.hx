package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.FactsView;
import anyparse.query.IndexScope;
import anyparse.query.ReachProject;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/** The call graph `thread-safety` reads, and how it reads the edges its compiler facts add. */
@:nullSafety(Strict)
final class ThreadGraph {

	/**
	 * The graph of `files`: when the project asks (`useFacts`, the `compilerFacts` option) and the run has them, read
	 * through the compiler facts of its configured oracles (`SymbolIndexHost.compilerFacts`) as the reach analyses read
	 * them — never the truth, so no file is dropped; by their syntax alone otherwise. Opt-in: a call the facts
	 * describe carries no receiver field (`CallEdge.receiverField`), so the locks its takes work go unnamed.
	 */
	public static function build(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, useFacts: Bool): CallGraph {
		if (!useFacts) return CallGraph.build(files, plugin);
		final index: SymbolIndex = IndexScope.report(files, plugin);
		return CallGraph.build(files, plugin, index, FactsView.ofRun(plugin, new ReachProject(plugin, index, files)));
	}

	/**
	 * Whether the `Ref` edge `edge` names no call its value is handed to while another `Ref` from the same function to the
	 * same value at the same span does: the facts file a nested function as a value made there (`CallGraphFacts`), the
	 * syntax as the argument of the call it is handed to, and only the latter says where it runs.
	 */
	public static function madeWhereHanded(graph: CallGraph, edge: CallEdge): Bool {
		final at: Null<Span> = edge.span;
		return edge.via == null && at != null
			&& graph.outEdges(edge.from)
				.exists(
					o -> o != edge && o.kind == Ref && o.to == edge.to && o.via != null && o.span?.from == at.from && o.span?.to == at.to
				);
	}

}
