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
		return CallGraph.build(rootModules(sources), new HaxeQueryPlugin());
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
						values: [],
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

	/**
	 * Each source as the module named after the first type it declares, under its package's directory (`Box.hx` for `class Box
	 * {…}`, `q/Quiet.hx` for `package q; class Quiet …`), a repeated one on another class path (`cp<i>/Box.hx`), `F<i>.hx`
	 * for one declaring none: the compiler binds a bare name to a module's MAIN type only, so a fixture whose files are named
	 * `F0.hx`, `F1.hx` hides every type it declares from the others.
	 */
	public static function rootModules(sources: Array<String>): Array<{ file: String, source: String }> {
		final declaration: EReg = ~/(class|interface|typedef|enum|abstract)\s+([A-Z][A-Za-z0-9_]*)/;
		final packageDecl: EReg = ~/^\s*package\s+([a-z0-9_.]+)\s*;/;
		final taken: Array<String> = [];
		return [
			for (i in 0...sources.length) {
				final dir: String = packageDecl.match(sources[i]) ? packageDecl.matched(1).split('.').join('/') + '/' : '';
				final named: String = declaration.match(sources[i]) ? '$dir${declaration.matched(2)}.hx' : '';
				// A second source of one module is that module on another class path, as the compiler would see two.
				final file: String = named == '' ? 'F$i.hx' : taken.contains(named) ? 'cp$i/$named' : named;
				taken.push(file);
				{ file: file, source: sources[i] };
			}
		];
	}

}
