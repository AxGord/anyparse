package anyparse.query.cli;

import anyparse.query.CallGraph;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.ExitCode.EXIT_USAGE;
import anyparse.query.GrammarPlugin;
import anyparse.query.cli.CliCallGraph.GraphOutput;
import anyparse.query.cli.CliCallGraph.GraphScope;
import anyparse.query.format.FlowJson;
import anyparse.query.format.FlowMermaid;
import anyparse.query.format.FlowText;
import anyparse.query.graph.FlowBuilder;
import anyparse.query.graph.FlowGraph;
import anyparse.runtime.Span;

/**
 * The one answer to "what does `graph --flow <Type.member>` print": the control-flow chart of the one function the
 * name resolves to in the scope (`FlowBuilder`), as a text report, a Mermaid flowchart or JSON.
 */
@:nullSafety(Strict)
final class GraphFlow {

	/** Draw the function `query` names in `inputSpecs`; the exit code of the run. */
	public static function run(
		cmd: String, query: String, inputSpecs: Array<String>, lang: String, output: GraphOutput, ctx: CliContext
	): Int {
		final scope: Null<GraphScope> = CliCallGraph.readScope(cmd, inputSpecs, lang);
		if (scope == null) return EXIT_RUNTIME;
		final calls: Null<CallGraph> = CliCallGraph.callGraphOf(cmd, scope);
		if (calls == null) return EXIT_RUNTIME;
		final matches: Array<FnNode> = calls.resolveTarget(query).filter(fn -> !fn.isExternal);
		if (matches.length == 0) {
			CliIo.stderr('apq $cmd: no function in scope matches "$query"\n');
			return ctx.emptyExit(true);
		}
		if (matches.length > 1) {
			CliIo.stderr('apq $cmd: "$query" matches ${matches.length} functions, name one of them:\n');
			for (fn in matches) CliIo.stderr('  ${fn.id}\n');
			return EXIT_USAGE;
		}
		final declared: Array<FnDeclaration> = calls.declarationsOf(matches[0].id);
		if (declared.length > 1) {
			CliIo.stderr('apq $cmd: "$query" is declared ${declared.length} times; a chart is of one declaration:\n');
			for (d in declared) CliIo.stderr('  ${d.file}:${d.span.lineCol(calls.sourceOf(d.file) ?? '').line}\n');
			return EXIT_USAGE;
		}
		final chart: Null<FlowGraph> = chartOf(matches[0], query, calls, scope.plugin);
		if (chart == null) {
			CliIo.stderr('apq $cmd: "$query" has no body to draw\n');
			return ctx.emptyExit(true);
		}
		CliIo.sysPrint( switch output {
			case Text: FlowText.write(chart);
			case Mermaid: FlowMermaid.write(chart, '$cmd --flow $query');
			case Json: FlowJson.write(chart);
		});
		return ctx.emptyExit(false);
	}

	/** The chart of `fn`, found in its file's tree by where it starts; null for a declaration with no body. */
	private static function chartOf(fn: FnNode, query: String, calls: CallGraph, plugin: GrammarPlugin): Null<FlowGraph> {
		final tree: Null<QueryNode> = calls.treeOf(fn.file);
		final source: Null<String> = calls.sourceOf(fn.file);
		final span: Null<Span> = fn.span;
		if (tree == null || source == null || span == null) return null;
		final node: Null<QueryNode> = TreePath.withSpan(tree, span);
		final typeName: Null<String> = fn.typeName;
		return node == null
			? null
			: FlowBuilder.build(
				node, typeName == null ? query : '$typeName.${fn.name}', plugin.refShape(), source, plugin.lexicalRegions(source)
			);
	}

}
