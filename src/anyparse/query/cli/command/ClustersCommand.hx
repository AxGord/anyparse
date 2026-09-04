package anyparse.query.cli.command;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.Clusters.ClusterReport;
import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq clusters` — partition a type's members by call-edge connectivity (hub bucket + components).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class ClustersCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'clusters';
	}

	public function summary(): String {
		return 'Partition a type\'s members by call-edge connectivity (hub bucket + components)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runClusters(args, ctx);
	}

	public function usage(): Void {
		printClustersUsage();
	}

	private static function runClusters(args: Array<String>, ctx: CliContext): Int {
		var lang: String = 'haxe';
		var hubCount: Null<Int> = null;
		var kinds: Null<Array<EdgeKind>> = null;
		var target: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--hubs':
					final raw: String = CliArgs.expectValue(args, ++i, '--hubs');
					final parsed: Null<Int> = Std.parseInt(raw);
					if (parsed == null || parsed < 0) {
						CliIo.stderr('apq clusters: --hubs expects a non-negative integer (0 = no hub extraction)\n');
						return EXIT_USAGE;
					}
					hubCount = parsed;
				case '--kinds':
					kinds = CliCallGraph.parseEdgeKinds('clusters', CliArgs.expectValue(args, ++i, '--kinds'));
					if (kinds == null) return EXIT_USAGE;
				case '-h', '--help':
					printClustersUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq clusters: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (target == null)
						target = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (target == null) {
			CliIo.stderr('apq clusters: missing <TypeName> argument\n');
			printClustersUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq clusters: missing <file-or-dir-or-glob> argument\n');
			printClustersUsage();
			return EXIT_USAGE;
		}
		final typeName: String = target;

		final built: Null<{ graph: CallGraph, sources: Map<String, String> }> = CliCallGraph.buildCallGraphScope(
			'clusters', inputSpecs, lang
		);
		if (built == null) return EXIT_RUNTIME;
		final graph: CallGraph = built.graph;
		final sources: Map<String, String> = built.sources;
		final report: Null<ClusterReport> = Clusters.analyze(graph, typeName, hubCount, kinds);
		if (report == null) {
			CliIo.stderr('apq clusters: no type in scope has members named "$typeName"\n');
			return ctx.emptyExit(true);
		}
		CliIo.sysPrint(Clusters.render(graph, report, f -> sources[f]));
		if (graph.unresolved.length > 0)
			CliIo.stderr('apq clusters: note — ${graph.unresolved.length} call site(s) unresolved; the graph is approximate\n');
		return ctx.emptyExit(false);
	}

	private static function printClustersUsage(): Void {
		CliIo.sysPrint('Usage: apq clusters <TypeName> <file-or-dir-or-glob>... [options]\n\n');
		CliIo.sysPrint('Partition analytics over the call graph: cluster the members of one type\n');
		CliIo.sysPrint('by intra-type call-edge connectivity, extracting high-fan-in hub members\n');
		CliIo.sysPrint('into a utils bucket first (else one hub glues everything into a blob).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --hubs <n>     Extract exactly the top-n fan-in hubs (0 = off; default auto)\n');
		CliIo.sysPrint('  --kinds <k,..> Edge kinds for connectivity: call,ref,new,virtual,contains (default call,ref,new)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
