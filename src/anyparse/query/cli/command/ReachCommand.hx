package anyparse.query.cli.command;

import anyparse.query.CallGraph.CallEdge;
import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq reach` — shortest call path(s) --from A --to B over the call graph.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class ReachCommand implements CliCommand {

	private static inline final DEFAULT_REACH_PATHS: Int = 10;

	public function new() {}

	public function name(): String {
		return 'reach';
	}

	public function summary(): String {
		return 'Shortest call path(s) --from A --to B over the call graph';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runReach(args, ctx);
	}

	public function usage(): Void {
		printReachUsage();
	}

	private static function runReach(args: Array<String>, ctx: CliContext): Int {
		var lang: String = 'haxe';
		var maxPaths: Int = DEFAULT_REACH_PATHS;
		var kinds: Null<Array<EdgeKind>> = null;
		var from: Null<String> = null;
		final toPatterns: Array<String> = [];
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--from':
					from = CliArgs.expectValue(args, ++i, '--from');
				case '--to':
					toPatterns.push(CliArgs.expectValue(args, ++i, '--to'));
				case '--max-paths':
					final raw: String = CliArgs.expectValue(args, ++i, '--max-paths');
					final parsedMax: Null<Int> = Std.parseInt(raw);
					if (parsedMax == null || parsedMax < 1) {
						CliIo.stderr('apq reach: --max-paths expects a positive integer\n');
						return EXIT_USAGE;
					}
					maxPaths = parsedMax;
				case '--kinds':
					kinds = CliCallGraph.parseEdgeKinds('reach', CliArgs.expectValue(args, ++i, '--kinds'));
					if (kinds == null) return EXIT_USAGE;
				case '-h', '--help':
					printReachUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq reach: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					inputSpecs.push(a);
			}
			i++;
		}
		if (from == null || toPatterns.length == 0) {
			CliIo.stderr('apq reach: both --from and --to are required\n');
			printReachUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq reach: missing <file-or-dir-or-glob> argument\n');
			printReachUsage();
			return EXIT_USAGE;
		}
		final fromStr: String = from;

		final built: Null<{ graph: CallGraph, sources: Map<String, String> }> = CliCallGraph.buildCallGraphScope('reach', inputSpecs, lang);
		if (built == null) return EXIT_RUNTIME;
		final graph: CallGraph = built.graph;
		final sources: Map<String, String> = built.sources;
		final fromIds: Array<String> = graph.matchIds(fromStr);
		final toIds: Array<String> = [];
		for (p in toPatterns) for (id in graph.matchIds(p)) if (!toIds.contains(id)) toIds.push(id);
		if (fromIds.length == 0) {
			CliIo.stderr('apq reach: no function in scope matches --from "$fromStr"\n');
			return ctx.emptyExit(true);
		}
		if (toIds.length == 0) {
			CliIo.stderr('apq reach: no function in scope matches --to ${toPatterns.join(', ')}\n');
			return ctx.emptyExit(true);
		}
		final effectiveKinds: Array<EdgeKind> = kinds ?? [Call, Ref, New, Virtual];
		final found: Array<Array<CallEdge>> = Reach.paths(graph, fromIds, toIds, maxPaths, effectiveKinds);
		for (path in found) CliIo.sysPrint('${Reach.render(graph, path, f -> sources[f])}\n');
		if (found.length == 0) CliIo.stderr('apq reach: no path found (${fromIds.length} from-node(s), ${toIds.length} to-node(s))\n');
		if (graph.unresolved.length > 0)
			CliIo.stderr('apq reach: note — ${graph.unresolved.length} call site(s) unresolved; the graph is approximate\n');
		return ctx.emptyExit(found.length == 0);
	}

	private static function printReachUsage(): Void {
		CliIo.sysPrint('Usage: apq reach --from <Type.method> --to <Type.method|Type.*> <file-or-dir-or-glob>... [options]\n\n');
		CliIo.sysPrint('Shortest call path(s) from --from to each --to (BFS; one path per pair).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --to <target>     Repeatable; accepts Type.method, bare method, Type.*\n');
		CliIo.sysPrint('  --max-paths <n>   Cap on reported paths (default $DEFAULT_REACH_PATHS)\n');
		CliIo.sysPrint('  --kinds <k,..>    Edge kinds to traverse (default call,ref,new,virtual)\n');
		CliIo.sysPrint('  --lang <name>     Grammar plugin (default haxe)\n');
	}

}
