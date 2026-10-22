package anyparse.check;

import anyparse.check.Check.FindingData;
import anyparse.core.PhaseTimings;
import anyparse.query.CallGraph;
import anyparse.query.Glob;
import anyparse.query.ReachLiveness;
import anyparse.runtime.Span;
import haxe.io.Path;

using Lambda;
using StringTools;

/**
 * Opt-in (`libraryBodies`): which library calls of the run BLOCK, read off the libraries' own bodies — the run's graph
 * holds only its own sources, so a call into a library with a Haxe body ends there, and blocking I/O inside it stays
 * invisible. The libraries of ONE shipped build (`LibraryBuild`) are read under that build's defines, every branch it does
 * not compile blanked out, and walked as a graph of their own: a library function blocks when it runs, through calls,
 * overrides and the function values it hands to a call that runs them there (not to a `spawns`, `marshals`, `registers` or
 * `neverInvokes` one), a sink of the library — a native it declares (`ProjectNatives`: an unknown native blocks), a
 * blocking call of the runtime (`PositiveSinks`), a `sinks` entry — that `nonBlocking` does not waive.
 *
 * The run's own graph is unchanged: each call it makes into such a function becomes a sink of the chains writing the
 * option (`PositiveSinks.library`), so a finding stays keyed at the PROJECT call site and names the library call as its
 * subject; its chain goes on into the library to the sink (`annotate`). Resolution inside the libraries is the graph's own
 * — by simple names, declared types and every override — so a library call is read as blocking along any path that
 * approximation admits.
 */
@:nullSafety(Strict)
final class LibraryBodies {

	/** The option naming the build whose libraries are walked: one `compilerOracle` entry's hxml. */
	public static inline final OPTION: String = 'libraryBodies';

	/** The option lists whose calls run a handed function value elsewhere, or never: the walk does not follow one. */
	private static final AWAY_KEYS: Array<String> = ['spawns', 'marshals', 'registers', 'neverInvokes'];

	/** The run's library calls whose bodies block: ids of external nodes of the run's graph. */
	public final ids: Array<String> = [];

	/** How many library files the walk holds, and how many it could not parse. */
	public final files: Int;

	public final skipped: Int;

	/** How many natives the libraries declare, and how many sinks the walk started from. */
	public final natives: Int;

	public final sinks: Int;

	/** Each id of `ids` -> the library chain to its sink, from the library member the call runs. */
	private final _chains: Map<String, Array<String>> = [];

	/** The `nonBlocking` patterns that waived a sink of the libraries. */
	private final _waivers: Array<String> = [];

	public function new(
		project: { graph: CallGraph, known: Array<String> }, plugin: GrammarPlugin, sources: Array<{ file: String, source: String }>,
		options: ThreadSafetyOptions
	) {
		PhaseTimings.time('library parse', () -> for (s in sources) try plugin.parseFile(s.source) catch (exception: haxe.Exception) {});
		final graph: CallGraph = PhaseTimings.measure('library graph', CallGraph.build.bind(sources, plugin));
		files = sources.length - graph.skippedFiles.length;
		skipped = graph.skippedFiles.length;
		final found: { ids: Array<String>, chains: Map<String, Array<String>>, waivers: Array<String> } = {
			ids: ids,
			chains: _chains,
			waivers: _waivers
		};
		final summary: { natives: Int, sinks: Int } = PhaseTimings.measure(
			'library summary', () -> summarise(project, graph, plugin, options, found)
		);
		natives = summary.natives;
		sinks = summary.sinks;
	}

	/** Whether the `nonBlocking` entry `pattern` waived a sink inside the libraries. */
	public inline function waives(pattern: String): Bool {
		return _waivers.contains(pattern);
	}

	/** The library chain of the blocking library call `id`, from the member it runs to the sink; null for any other id. */
	public inline function chainOf(id: String): Null<Array<String>> {
		return _chains[id];
	}

	/**
	 * Carries each finding of `violations` naming a blocking library call into the library: its chain goes on to the sink,
	 * and its message says the way.
	 */
	public function annotate(violations: Array<Violation>): Void {
		for (v in violations) {
			final data: Null<FindingData> = v.data;
			if (data == null) continue;
			final tails: Array<String> = [];
			final named: Array<String> = [];
			for (id in data.chain) {
				final chain: Null<Array<String>> = _chains[id];
				if (chain == null || named.contains(id)) continue;
				named.push(id);
				final tail: Array<String> = chain[0] == id ? chain.slice(1) : chain;
				for (t in tail) tails.push(t);
				v.message += ' — inside the library: ${ThreadSafety.elided([id].concat(tail), ThreadSafety.CHAIN_CAP)}';
			}
			if (tails.length > 0) data.chain = data.chain.concat(tails);
		}
	}

	/** What the run's notice adds when the libraries were walked. */
	public function notice(): String {
		return ', and ${ids.length} library call(s) whose bodies block ($files library file(s) walked, $skipped unparsed, $natives'
			+ ' library native(s), $sinks library sink(s))';
	}

	/**
	 * The libraries of the run `files` walked for the first chain writing `libraryBodies` (null when none does): the
	 * `compilerOracle` entry whose hxml it names, read (`LibraryBuild`), its library sources read and blanked where the
	 * build compiles nothing. Every reason a walk is not made, or made for one build of several, lands in `problems`.
	 */
	public static function forRun(
		files: Array<{ file: String, source: String }>, resolve: Null<(String) -> LintConfig>,
		project: { graph: CallGraph, sinks: PositiveSinks }, plugin: GrammarPlugin, problems: Array<String>
	): Null<LibraryBodies> {
		#if (sys || nodejs)
		final configs: Array<LintConfig> = [];
		for (f in files) {
			final config: LintConfig = LintConfig.resolveWith(resolve, f.file);
			if (!configs.contains(config)) configs.push(config);
		}
		var chosen: Null<{ config: LintConfig, options: ThreadSafetyOptions, entry: String }> = null;
		for (config in configs) {
			final options: ThreadSafetyOptions = ThreadSafetyOptions.read(config);
			final entries: Array<String> = options.list(OPTION);
			if (entries.length == 0) continue;
			final held: Null<{ config: LintConfig, options: ThreadSafetyOptions, entry: String }> = chosen;
			if (held != null) {
				if (entries[0] != held.entry)
					problems.push('$OPTION differs between the chains of the run — "${held.entry}" is walked for all');
				continue;
			}
			if (entries.length > 1) problems.push('$OPTION names ${entries.length} builds — only the first, "${entries[0]}", is walked');
			chosen = { config: config, options: options, entry: entries[0] };
		}
		final picked: Null<{ config: LintConfig, options: ThreadSafetyOptions, entry: String }> = chosen;
		if (picked == null) return null;
		final written: String = Path.normalize(picked.entry);
		final oracle: Null<LintConfig.OracleConfig> = picked.config.compilerOracles().find(o -> {
			final hxml: String = Path.normalize(o.hxml);
			hxml == written || hxml.endsWith('/$written');
		});
		if (oracle == null) {
			problems.push('$OPTION "${picked.entry}" names no compilerOracle entry\'s hxml — no library body is walked');
			return null;
		}
		final build: Null<LibraryBuild> = PhaseTimings.measure(
			'library build read', () -> LibraryBuild.read(oracle, [for (f in files) f.file], problems)
		);
		if (build == null) return null;
		final sources: Array<{ file: String, source: String }> = PhaseTimings.measure(
			'library read', () -> readSources(build.classPaths, build.target)
		);
		final kept: Array<{ file: String, source: String }> = PhaseTimings.measure('library defines', () -> {
			final liveness: ReachLiveness = new ReachLiveness(plugin, [
				{
					name: OPTION,
					defined: build.defined,
					everDefined: build.defined,
					values: build.values,
					compiled: [],
					types: []
				}
			]);
			[
				for (s in sources) { file: s.file, source: blanked(s.source, liveness.skippedOf(s.file, s.source)) }
			];
		});
		return new LibraryBodies(
			{ graph: project.graph, known: project.sinks.builtin.concat(project.sinks.natives) }, plugin, kept, picked.options
		);
		#else
		return null;
		#end
	}

	/**
	 * Walks the library graph `graph` from its sinks back to every function that runs one, then marks each external call of
	 * `project` whose library member reaches one into `found`; answers how many natives and sinks the walk started from.
	 */
	private static function summarise(
		project: { graph: CallGraph, known: Array<String> }, graph: CallGraph, plugin: GrammarPlugin, options: ThreadSafetyOptions,
		found: { ids: Array<String>, chains: Map<String, Array<String>>, waivers: Array<String> }
	): { natives: Int, sinks: Int } {
		final natives: ProjectNatives = new ProjectNatives(graph, plugin);
		final sinkIds: Map<String, Bool> = sinksOf(graph, new PositiveSinks(graph, plugin, natives, null), options, found.waivers);
		final next: Map<String, String> = hopsTo(graph, sinkIds, options);
		// a type the run declares is the project's, whatever library type shares its name: one with a function of its own,
		// or one extending another
		final functions: Map<String, Bool> = [];
		for (node in project.graph.nodes) {
			final type: Null<String> = node.typeName;
			if (!node.isExternal && type != null) functions[type] = true;
		}
		final declared: (String) -> Bool = t -> functions.exists(t) || project.graph.types.superclassOf(t) != null;
		// a builtin sink or a project native is a sink already, read as the runtime's or the project's own
		for (id => node in project.graph.nodes) if (node.isExternal && !project.known.contains(id)) {
			final type: Null<String> = node.typeName;
			final name: Null<String> = node.name;
			if (type == null || name == null) continue;
			final chain: Null<Array<String>> = blockingChain(
				project.graph, graph, { type: type, name: name, declared: declared }, sinkIds, next
			);
			if (chain == null) continue;
			found.ids.push(id);
			found.chains[id] = chain;
		}
		return { natives: natives.ids.length, sinks: sinkIds.count() };
	}

	/**
	 * The sinks of the library graph `graph`: its natives and the runtime's blocking calls it makes (`positive`), and the
	 * `sinks` entries of `options`; a `nonBlocking` entry waives a native or a builtin one, noted in `waivers`.
	 */
	private static function sinksOf(
		graph: CallGraph, positive: PositiveSinks, options: ThreadSafetyOptions, waivers: Array<String>
	): Map<String, Bool> {
		final configured: Array<String> = [for (p in options.list('sinks')) for (id in graph.matchIds(p)) id];
		final sinkIds: Map<String, Bool> = [for (id in configured) id => true];
		for (id in positive.builtin.concat(positive.natives)) sinkIds[id] = true;
		for (pattern in options.nonBlocking) for (id in graph.matchIds(pattern)) if (sinkIds.exists(id) && !configured.contains(id)) {
			sinkIds.remove(id);
			if (!waivers.contains(pattern)) waivers.push(pattern);
		}
		return sinkIds;
	}

	/**
	 * One walk back from every sink of `sinkIds` over `graph`: each function that runs one (`runsThere`, the away calls
	 * `options` lists) -> its first hop on a shortest way to one.
	 */
	private static function hopsTo(graph: CallGraph, sinkIds: Map<String, Bool>, options: ThreadSafetyOptions): Map<String, String> {
		final away: Array<String> = [for (key in AWAY_KEYS) for (p in options.list(key)) p];
		final awayIds: Map<String, Bool> = [for (p in away) for (id in graph.matchIds(p)) id => true];
		final awayNames: Array<String> = [for (p in away) if (p.indexOf('.') < 0) p];
		final next: Map<String, String> = [];
		final queue: Array<String> = [for (id in sinkIds.keys()) id];
		var qi: Int = 0;
		while (qi < queue.length) {
			final at: String = queue[qi++];
			for (e in graph.inEdges(at)) if (!sinkIds.exists(e.from) && !next.exists(e.from) && runsThere(e, awayIds, awayNames)) {
				next[e.from] = at;
				queue.push(e.from);
			}
		}
		return next;
	}

	/**
	 * The shortest library chain to a sink from what a call of `call.type`'s member `call.name` runs — the member the
	 * library type declares or inherits, every override of it in the libraries, a constructor's field initializers; for a
	 * type the run declares (`call.declared`), the member its nearest library superclass declares or inherits, and no
	 * library override: a value of a project type is no instance of a library subclass — or null when none reaches one.
	 */
	private static function blockingChain(
		project: CallGraph, graph: CallGraph, call: { type: String, name: String, declared: (String) -> Bool }, sinkIds: Map<String, Bool>,
		next: Map<String, String>
	): Null<Array<String>> {
		final name: String = call.name;
		final runs: Array<String> = [];
		final seen: Array<String> = [];
		var at: Null<String> = call.type;
		while (at != null && !seen.contains(at)) {
			final owner: String = at;
			seen.push(owner);
			final member: Null<String> = call.declared(owner) ? null : graph.memberOnChain(owner, name);
			if (member != null) {
				runs.push(member);
				// a constructor builds exactly its type; any other member of a library type may dispatch to an override
				if (owner == call.type && name != 'new') for (o in graph.virtualTargets(owner, name)) if (!runs.contains(o)) runs.push(o);
				if (name == 'new' && graph.nodes.exists('$owner.<init>')) runs.push('$owner.<init>');
				break;
			}
			at = call.declared(owner) ? project.types.superclassOf(owner) : null;
		}
		var best: Null<Array<String>> = null;
		for (r in runs) {
			final chain: Array<String> = [r];
			var cursor: String = r;
			while (!sinkIds.exists(cursor)) {
				final hop: Null<String> = next[cursor];
				if (hop == null) break;
				chain.push(hop);
				cursor = hop;
			}
			final shortest: Null<Array<String>> = best;
			if (sinkIds.exists(cursor) && (shortest == null || chain.length < shortest.length)) best = chain;
		}
		return best;
	}

	/**
	 * Whether the edge `e` runs its target while its function runs: a call, or a function value handed to a call that is no
	 * `away` one (by id, or a bare name of one) — a value stored or returned runs elsewhere.
	 */
	private static function runsThere(e: CallEdge, awayIds: Map<String, Bool>, awayNames: Array<String>): Bool {
		if (e.kind.isInvocation()) return true;
		final via: Null<String> = e.via;
		return e.kind == Ref && via != null && !awayIds.exists(via) && !awayNames.contains(e.viaMember ?? '');
	}

	/** `source` with every range of `dead` blanked — each character but a line break turned a space — its offsets kept. */
	private static function blanked(source: String, dead: Array<Span>): String {
		if (dead.length == 0) return source;
		final out: StringBuf = new StringBuf();
		var at: Int = 0;
		// ranges ordered by their start; one may lie inside another
		for (d in dead) if (d.to > at) {
			final from: Int = d.from > at ? d.from : at;
			out.add(source.substring(at, from));
			out.add(~/[^\r\n]/g.replace(source.substring(from, d.to), ' '));
			at = d.to;
		}
		out.add(source.substring(at));
		return out.toString();
	}

	#if (sys || nodejs)
	/** Every `.hx` under `classPaths` that a build for `target` may compile (`LibraryBuild.compiles`) and can be read, each once. */
	private static function readSources(classPaths: Array<String>, target: Null<String>): Array<{ file: String, source: String }> {
		final out: Array<{ file: String, source: String }> = [];
		final seen: Map<String, Bool> = [];
		for (dir in classPaths) for (path in Glob.expand(dir, '.hx')) if (!seen.exists(path)) {
			seen[path] = true;
			final relative: String = path.substr(dir.length + 1);
			if (!LibraryBuild.compiles(relative, target, p -> sys.FileSystem.exists('$dir/$p'))) continue;
			final source: Null<String> = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
			if (source != null) out.push({ file: path, source: source });
		}
		return out;
	}
	#end

}
