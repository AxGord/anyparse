package anyparse.query.cli;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.cli.CliArgs;
import anyparse.runtime.ParseError;
import haxe.Exception;

using StringTools;

/**
 * The call graph `callees` / `callers` / `reach` / `clusters` all build.
 *
 * The four commands differ in what they ask the graph, not in how they build it:
 * one scope walk, one edge-kind set. Both halves lived in `Cli` and are shared
 * by construction, so they belong beside the commands rather than inside any one
 * of them.
 */
@:nullSafety(Strict)
final class CliCallGraph {

	/**
	 * Shared scope→graph builder for the `callees` / `callers` / `reach`
	 * subcommands: expands inputs, reads sources (kept for `line:col`
	 * rendering), warms the parse cache with progress feedback, and builds
	 * the `CallGraph`. Null on an empty scope (message already printed).
	 */
	public static function buildCallGraphScope(
		cmd: String, inputSpecs: Array<String>, lang: String
	): Null<{ graph: CallGraph, sources: Map<String, String> }> {
		final cached: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final expanded: ExpandedInputs = CliArgs.expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq $cmd: no input files matched ${CliArgs.quotedSpecs(inputSpecs)}\n');
			return null;
		}
		final files: Array<{ file: String, source: String }> = [];
		final sources: Map<String, String> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			files.push({ file: path, source: source });
			sources[path] = source;
			try cached.parseFile(source) catch (exception: ParseError) {} catch (exception: Exception) {}
			CliIo.streamProgress(cmd, ++scanned, paths.length, expanded.singleFile);
		}
		final graph: CallGraph = CallGraph.build(files, cached);
		if (graph.skippedFiles.length > 0) {
			final shown: Array<String> = graph.skippedFiles.slice(0, CliWalk.SKIP_PATHS_SHOWN);
			CliIo.stderr('apq $cmd: WARNING ${graph.skippedFiles.length} file(s) failed to parse and are invisible to the graph:\n');
			for (p in shown) CliIo.stderr('  $p\n');
			if (graph.skippedFiles.length > shown.length) CliIo.stderr('  ... +${graph.skippedFiles.length - shown.length} more\n');
			if (expanded.singleFile) return null;
		}
		return { graph: graph, sources: sources };
	}

	/** Parse a `--kinds call,ref,new,virtual,contains` value. Null on an unknown kind (message printed). */
	public static function parseEdgeKinds(cmd: String, value: String): Null<Array<EdgeKind>> {
		final result: Array<EdgeKind> = [];
		for (part in value.split(',')) {
			final token: String = StringTools.trim(part);
			final kind: Null<EdgeKind> = switch token {
				case 'call': Call;
				case 'ref': Ref;
				case 'new': New;
				case 'virtual': Virtual;
				case 'contains': Contains;
				case _: null;
			};
			if (kind == null) {
				CliIo.stderr('apq $cmd: unknown edge kind "$token" (call, ref, new, virtual, contains)\n');
				return null;
			}
			result.push(kind);
		}
		return result;
	}

}
