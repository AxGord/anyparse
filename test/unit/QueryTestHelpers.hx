package unit;

import anyparse.check.OracleCoverage;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.CachingGrammarPlugin.ResolutionSources;
import anyparse.query.CallGraph;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.SymbolIndex;

/**
 * Shared fixture builders for the query-layer test suites.
 */
@:nullSafety(Strict)
final class QueryTestHelpers {

	/**
	 * Build a CallGraph over inline sources, one synthetic file per entry.
	 */
	public static function graphOf(sources: Array<String>): CallGraph {
		final files: Array<{ file: String, source: String }> = [
			for (i in 0...sources.length) { file: 'F$i.hx', source: sources[i] }
		];
		return CallGraph.build(files, new HaxeQueryPlugin());
	}

	/**
	 * A plugin whose run declared project roots that matched: `project` is the report and the whole
	 * project, `library` the read-only rest of the resolution scope. What a `lint` run over a project
	 * with `resolutionRoots` hands its checks; `allRootsMatched` false stands for a run where some
	 * declared root matched nothing. `classpathComplete` stands for a run whose oracle list is declared complete: one
	 * build that defines nothing and compiles exactly the project and `library`, every type they declare typed.
	 */
	public static function projectPlugin(
		project: Array<{ file: String, source: String }>, ?library: Array<{ file: String, source: String }>, allRootsMatched: Bool = true,
		classpathComplete: Bool = true
	): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final libraryFiles: Array<{ file: String, source: String }> = library ?? [];
		final cwd: String = Sys.getCwd();
		function builds(): ReachBuilds {
			final all: Array<{ file: String, source: String }> = project.concat(libraryFiles);
			final index: SymbolIndex = SymbolIndex.build(all, new HaxeQueryPlugin());
			final types: Array<{ name: String, file: String }> = [];
			for (fi in index.allFiles()) for (t in fi.types) types.push({ name: t.name, file: OracleCoverage.canonical(cwd, fi.file) });
			return {
				configurations: [
					{
						name: 'complete',
						defined: [],
						everDefined: [],
						compiled: [for (f in all) OracleCoverage.canonical(cwd, f.file)],
						types: types
					}
				],
				library: libraryFiles
			};
		}
		final sources: () -> ResolutionSources = () -> {
			report: project,
			projectRoots: [],
			library: new LibrarySources(libraryFiles),
			rootsMatched: true,
			rootsAllMatched: allRootsMatched
		};
		plugin.setResolutionScope(
			classpathComplete ? { declared: true, sources: sources, builds: builds } : { declared: true, sources: sources }
		);
		return plugin;
	}

}
