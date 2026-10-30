package anyparse.query.cli;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.GitRevision.RevisionFile;
import anyparse.query.cli.UsageFailure;
import anyparse.query.format.GraphJson;
import anyparse.query.format.GraphMermaid;
import anyparse.query.graph.CodeGraph;
import anyparse.runtime.ParseError;

/** The scope a graph command reads: its files with their sources, the caching plugin that parsed them, whether one file was named. */
typedef GraphScope = {
	final files: Array<{ file: String, source: String }>;
	final sources: Map<String, String>;
	final plugin: GrammarPlugin;
	final singleFile: Bool;
}

/**
 * What a call-graph command prints: its text report, or the graph it walked as a Mermaid flowchart or
 * a JSON document (`anyparse.query.graph`).
 */
enum abstract GraphOutput(String) {

	final Text = 'text';
	final Mermaid = 'mermaid';
	final Json = 'json';

}

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
		final scope: Null<GraphScope> = readScope(cmd, inputSpecs, lang);
		if (scope == null) return null;
		final graph: Null<CallGraph> = callGraphOf(cmd, scope);
		return graph == null ? null : { graph: graph, sources: scope.sources };
	}

	/** The call graph of `scope`, warning of every file that failed to parse; null when the one file named did (message printed). */
	public static function callGraphOf(cmd: String, scope: GraphScope): Null<CallGraph> {
		final graph: CallGraph = CallGraph.build(scope.files, scope.plugin);
		return skippedEndRun(cmd, graph.skippedFiles, scope) ? null : graph;
	}

	/**
	 * The files of a graph command's scope as revision `ref` holds them (`GitRevision.filesAt`), none when it holds
	 * none, each parsed once into the caching plugin returned with them. `texts` maps an object id to its text, shared
	 * by the revisions one run reads so a file both hold alike is read once. Null when a file cannot be read or git
	 * lists no tree for `ref` (message printed).
	 */
	public static function revisionScope(
		cmd: String, ref: String, inputSpecs: Array<String>, lang: String, texts: Map<String, String>
	): Null<GraphScope> {
		final cached: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final listed: Null<Array<RevisionFile>> = GitRevision.filesAt(ref, inputSpecs, CliArgs.sourceExtensionOf(cached.langName()));
		if (listed == null) {
			CliIo.stderr('apq $cmd: git lists no tree for "$ref"\n');
			return null;
		}
		final files: Array<{ file: String, source: String }> = [];
		final sources: Map<String, String> = [];
		var scanned: Int = 0;
		for (f in listed) {
			final source: Null<String> = texts[f.blob] ?? GitRevision.blobText(f.blob);
			if (source == null) {
				CliIo.stderr('apq $cmd: ${f.path} is not readable at "$ref"\n');
				return null;
			}
			texts[f.blob] = source;
			files.push({ file: f.path, source: source });
			sources[f.path] = source;
			try cached.parseFile(source) catch (exception: ParseError) {} catch (exception: Exception) {}
			CliIo.streamProgress(cmd, ++scanned, listed.length, false);
		}
		return {
			files: files,
			sources: sources,
			plugin: cached,
			singleFile: false
		};
	}

	/**
	 * The files of a graph command's scope, read, each parsed once into the caching plugin returned with them, with
	 * progress feedback. Null on an empty scope (message already printed).
	 */
	public static function readScope(cmd: String, inputSpecs: Array<String>, lang: String): Null<GraphScope> {
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
		return {
			files: files,
			sources: sources,
			plugin: cached,
			singleFile: expanded.singleFile
		};
	}

	/**
	 * Warn that the files of `skipped` failed to parse and are invisible to the graph, and answer whether the run ends:
	 * it does when the scope is one named file, which leaves no graph to draw.
	 */
	public static function skippedEndRun(cmd: String, skipped: Array<String>, scope: GraphScope): Bool {
		if (skipped.length == 0) return false;
		final shown: Array<String> = skipped.slice(0, CliWalk.SKIP_PATHS_SHOWN);
		CliIo.stderr('apq $cmd: WARNING ${skipped.length} file(s) failed to parse and are invisible to the graph:\n');
		for (p in shown) CliIo.stderr('  $p\n');
		if (skipped.length > shown.length) CliIo.stderr('  ... +${skipped.length - shown.length} more\n');
		return scope.singleFile;
	}

	/** Parse a `--kinds call,ref,new,virtual,contains,accessor` value. Null on an unknown kind (message printed). */
	public static function parseEdgeKinds(cmd: String, value: String): Null<Array<EdgeKind>> {
		final result: Array<EdgeKind> = [];
		for (part in value.split(',')) {
			final token: String = part.trim();
			final kind: Null<EdgeKind> = switch token {
				case 'call': Call;
				case 'ref': Ref;
				case 'new': New;
				case 'virtual': Virtual;
				case 'contains': Contains;
				case 'accessor': Accessor;
				case _: null;
			};
			if (kind == null) {
				CliIo.stderr('apq $cmd: unknown edge kind "$token" (call, ref, new, virtual, contains, accessor)\n');
				return null;
			}
			result.push(kind);
		}
		return result;
	}

	/** Parse a `--format text|mermaid|json` value of a call-graph command; an unknown one is a `UsageFailure`. */
	public static function parseGraphOutput(value: String): GraphOutput {
		return switch value {
			case 'text': Text;
			case 'mermaid': Mermaid;
			case 'json': Json;
			case _: throw new UsageFailure('unknown --format "$value" (text, mermaid, json)');
		};
	}

	/** Print `graph` as `output` asks — Mermaid with `caption` as its comment line, or JSON. */
	public static function printGraph(output: GraphOutput, graph: CodeGraph, caption: String): Void {
		switch output {
			case Mermaid:
				CliIo.sysPrint(GraphMermaid.write(graph, caption));
			case Json:
				CliIo.sysPrint(GraphJson.write(graph));
			case Text:
				throw new Exception('the text report of a call-graph command is its own');
		}
	}

}
