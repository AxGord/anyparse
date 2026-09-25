package;

import anyparse.check.LintConfig;
import anyparse.check.OracleGeneration;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CallGraph;
import anyparse.query.CompilerFacts;
import anyparse.query.FactsView;
import anyparse.query.HaxelibResolver;
import anyparse.query.ReachProject;
import anyparse.query.StdResolver;
import anyparse.query.SymbolIndex;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The edge-diff harness of the compiler-facts call graph: over the project in the working directory (its `apqlint.json`
 * names the roots, the libraries and the compiler oracles), build the call graph twice — by syntax alone and with the
 * compiler facts — and write, for every function the facts replaced, the records each reading gives it: its edges but
 * lexical containment, its unresolved calls and its unresolved accesses, one JSON line per function.
 *
 *   haxe tools/edge-diff.hxml
 *   (cd <project> && node <anyparse>/bin/edge-diff.js <out.jsonl>)
 */
@:nullSafety(Strict)
final class EdgeDiff {

	public static function main(): Void {
		final args: Array<String> = Sys.args();
		if (args.length != 1) {
			Sys.println('usage: edge-diff <out.jsonl>');
			Sys.exit(2);
		}
		final cwd: String = Sys.getCwd();
		final config: LintConfig = LintConfig.discover(Path.join([cwd, 'EdgeDiff.hx']));
		final project: Array<{ file: String, source: String }> = [];
		for (root in config.resolutionRoots()) collect(root, project);
		final libs: Array<{ file: String, source: String }> = [];
		for (name in config.resolutionLibs()) {
			final dir: Null<String> = HaxelibResolver.libSourceDir(name);
			if (dir != null) collect(dir, libs);
		}
		final std: Null<String> = StdResolver.stdDir();
		if (std != null) collect(std, libs);
		final held: Map<String, Bool> = [for (f in project) FileSystem.fullPath(f.file) => true];
		final library: Array<{ file: String, source: String }> = [for (f in libs) if (!held.exists(FileSystem.fullPath(f.file))) f];
		final oracles: Array<OracleConfig> = OracleGeneration.prepare(config.compilerOracles()).oracles;
		final started: Float = Sys.time();
		final facts: Null<CompilerFacts> = TypedFactsProbe.probeAll(oracles);
		Sys.println('facts: ${Math.round(Sys.time() - started)}s, configurations ${facts?.configurations}, dropped ${facts?.dropped}');
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final index: SymbolIndex = SymbolIndex.build(project.concat(library), plugin, [for (f in library) f.file]);
		final view: Null<FactsView> = FactsView.of(facts, new ReachProject(plugin, index, project));
		final plain: CallGraph = CallGraph.build(project, plugin, index);
		final typed: CallGraph = CallGraph.build(project, plugin, index, view);
		final out: Array<String> = [];
		var functions: Int = 0;
		for (n in typed.nodes) if (!n.isExternal && n.span != null) functions++;
		for (id => _ in typed.facts?.faceted ?? []) {
			final node: Null<FnNode> = typed.node(id);
			out.push(Json.stringify({
				id: id,
				file: node?.file,
				syntax: records(plain, id),
				facts: records(typed, id)
			}));
		}
		File.saveContent(args[0], out.join('\n') + '\n');
		Sys.println('functions ${functions}, faceted ${out.length}');
	}

	/** Every `.hx` file under `dir`, read. */
	private static function collect(dir: String, into: Array<{ file: String, source: String }>): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(path))
				collect(path, into)
			else if (StringTools.endsWith(entry, '.hx'))
				into.push({ file: path, source: File.getContent(path) });
		}
	}

	/** The records of node `id` in `g`: `<kind> <target> @<offset>`, `unresolved <reason> @<offset>`, `access <member> @<offset>`. */
	private static function records(g: CallGraph, id: String): Array<String> {
		final out: Array<String> = [];
		for (e in g.outEdges(id)) if (e.kind != Contains) out.push('${e.kind.label()} ${e.to} @${e.span?.from ?? -1}');
		for (u in g.unresolved) if (u.from == id)
			out.push('unresolved ${u.reason.getName()}(${u.reason.getParameters().join(',')}) @${u.span?.from ?? -1}');
		for (a in g.unresolvedAccess) if (a.from == id) out.push('access ${a.member} @${a.span?.from ?? -1}');
		out.sort(Reflect.compare);
		return out;
	}

}
