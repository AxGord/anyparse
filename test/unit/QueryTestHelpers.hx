package unit;

import anyparse.check.OracleCoverage;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.CachingGrammarPlugin.ResolutionSources;
import anyparse.query.CallGraph;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.ReachLiveness.ReachConfiguration;
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
	 * The path of the std's own module file `relative` (`Array.hx`) under the std the run resolves (`StdResolver.stdDir`):
	 * where a std stub must sit for the index to take it for the std's own declaration (`StdResolver.isStdFile`) — a stub
	 * anywhere else is a project or library type at a std path, which shadows the std's. Under `std/` with no std found.
	 */
	public static function stdPath(relative: String): String {
		final dir: Null<String> = anyparse.query.StdResolver.stdDir();
		return dir == null ? 'std/$relative' : haxe.io.Path.join([dir, relative]);
	}

	/**
	 * A plugin whose run declared project roots that matched: `project` is the report and the whole
	 * project, `library` the read-only rest of the resolution scope. What a `lint` run over a project
	 * with `resolutionRoots` hands its checks; `allRootsMatched` false stands for a run where some
	 * declared root matched nothing. `classpathComplete` stands for a run whose oracle list is declared complete: one
	 * build that defines nothing and compiles exactly the project and `library`, every type they declare typed — or, given
	 * `defines`, one such build per entry, which sets those defines.
	 */
	public static function projectPlugin(
		project: Array<{ file: String, source: String }>, ?library: Array<{ file: String, source: String }>, allRootsMatched: Bool = true,
		classpathComplete: Bool = true, ?defines: Array<ReachConfiguration>
	): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final libraryFiles: Array<{ file: String, source: String }> = library ?? [];
		final cwd: String = Sys.getCwd();
		final declared: Array<ReachConfiguration> = defines ?? [
			{
				name: 'complete',
				defined: [],
				everDefined: [],
				values: [],
				compiled: [],
				types: []
			}
		];
		function builds(): ReachBuilds {
			final all: Array<{ file: String, source: String }> = project.concat(libraryFiles);
			final index: SymbolIndex = CheckFixture.index(all, new HaxeQueryPlugin());
			final types: Array<{ name: String, file: String }> = [];
			for (fi in index.allFiles()) for (t in fi.types) types.push({ name: t.name, file: OracleCoverage.canonical(cwd, fi.file) });
			final compiled: Array<String> = [for (f in all) OracleCoverage.canonical(cwd, f.file)];
			return {
				configurations: [
					for (c in declared)
						{
							name: c.name,
							defined: c.defined,
							everDefined: c.everDefined,
							values: c.values,
							compiled: compiled,
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
			classpathComplete || defines != null
				? { declared: true, sources: sources, builds: builds }
				: { declared: true, sources: sources }
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
