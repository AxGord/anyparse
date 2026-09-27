package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.GraphScoped;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.LockSites.LockPair;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * One `apqlint.json` chain's `thread-safety` lists: the three name lists resolved to graph ids, the lock pairs as
 * written (a malformed one is reported) and as resolved.
 */
private typedef ChainLists = {

	/** Whether the chain names any `sinks` — a chain that names none is read for the graph and reports nothing. */
	final reports: Bool;

	final sinkIds: Array<String>;
	final spawnIds: Array<String>;
	final marshalIds: Array<String>;
	final quietIds: Array<String>;
	final lockPairs: Array<String>;
	final pairs: Array<LockPair>;
}

/**
 * Config-driven thread-context analysis over the approximate `CallGraph` — finds the two classic main-thread stalls:
 * (a) a MAIN-context function calling a configured blocking sink; (b) a function holding a configured lock across a
 * call that transitively reaches a sink, while the main thread takes that lock somewhere.
 *
 * Context propagation: graph roots start MAIN; a callback passed to a `spawns` target runs BG, one passed to a
 * `marshals` target runs MAIN, any other inherits its registrar's context. A node with no resolved callers is ASSUMED
 * main — the over-approximation a finder wants. Sinks inside a `marshals` function's own body are the primitive's
 * machinery and are not reported.
 *
 * Locks are told apart by the OBJECT (`LockSites`: the sealed member holding it). A sink that TAKES a `lockPairs` lock
 * stalls only when the lock is LONG: some function holds it, on some path (`LockWindow`), across a call that blocks;
 * leaves it held on a path out of the function; or releases it without taking it. A lock no sealed member names is
 * always long, so an unknown lock keeps every report; a hold in the owner's constructor before the object escapes
 * blocks no one. Holding a long lock is itself blocking, so the locks and the taint are solved together.
 *
 * Configured per project in `apqlint.json` (the rule is inert without it):
 *
 *     "thread-safety": {
 *         "sinks":     ["app.Mutex.lock", "Sys.sleep", "sys.io.File.*"],
 *         "spawns":    ["app.Worker.spawn", "Thread.create"],
 *         "marshals":  ["app.Worker.runOnMain"],
 *         "lockPairs": ["app.Mutex.lock/unlock", "RwLock.lock/unlock"],
 *         "quietRoots": ["app.App.shutdown"],
 *         "exclude":   ["test"]
 *     }
 *
 * `exclude` drops files whose path contains an entry as a '/'-bounded segment run BEFORE the graph is built. Patterns
 * are matched by their last two dot-segments (`SymbolIndex` models no packages); `Type.*` covers every recorded member
 * of a type. A `lockPairs` entry is `<lock pattern>/<unlock member name>` on the same type. A call of a lock WRAPPER
 * (`LockSites`) takes or gives back its lock with no entry of its own. The main thread entering a `quietRoots`
 * function — a shutdown or crash path that blocks on purpose — goes on QUIET: what only such paths reach is reported
 * neither as a main-thread sink call nor as a main-thread take of a lock, and every other path still is.
 */
@:nullSafety(Strict)
final class ThreadSafety implements Check implements ConfigAware implements NoAutofix implements GraphScoped {

	private static inline final CTX_MAIN: Int = 1;
	private static inline final CTX_BG: Int = 2;

	/** The main thread on a path through a `quietRoots` function: reached, but never reported. */
	private static inline final CTX_QUIET: Int = 4;

	/** A background thread on a path through a `quietRoots` function: what it marshals to the main thread is QUIET. */
	private static inline final CTX_BG_QUIET: Int = 8;

	private static inline final CTX_LOUD: Int = CTX_MAIN | CTX_BG;
	private static inline final CTX_QUIETED: Int = CTX_QUIET | CTX_BG_QUIET;
	private static inline final CHAIN_CAP: Int = 8;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'thread-safety';
	}

	public function description(): String {
		return 'main-thread-reachable blocking calls and locks held across blocking calls (config-driven)';
	}

	/**
	 * ONE graph over every file of the run, whatever config chains they span — a file whose chain names no `sinks`
	 * included, since its calls and registrations shape the other files' contexts — and each SITE judged by the chain
	 * of its own file: a call is a sink call when its call site's chain lists that sink, a callback is spawned or
	 * marshalled when the registering site's chain lists that target, a lock window opens under its file's
	 * `lockPairs`. Reachability stays whole-graph, so a single-chain run is unchanged and a main-thread caller in one
	 * chain still reaches a sink call in another.
	 */
	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		if (files.length == 0) return [];
		// `Linter.collect` hands over every file but an `exclude`d one (`scanSkipReason`), and drops the findings in a
		// file with no `sinks` of its own afterwards (`skipReason`).
		final graph: CallGraph = CallGraph.build(files, plugin);
		final sets: Array<ChainLists> = [];
		final byFile: Map<String, ChainLists> = listsByFile(files, graph, sets);
		final sinkIds: Array<String> = [];
		for (lists in sets) for (id in lists.sinkIds) if (!sinkIds.contains(id)) sinkIds.push(id);
		if (sinkIds.length == 0) return [];
		final listsOf: (String) -> ChainLists = listsOfFile.bind(byFile);

		final contexts: Map<String, Int> = [];
		final mainParent: Map<String, CallEdge> = [];
		// a quiet root is judged by the chain of the file declaring it
		final quiet: Array<String> = [
			for (id => node in graph.nodes) if (byFile[node.file]?.quietIds.contains(id) == true) id
		];
		propagateContexts(graph, listsOf, quiet, contexts, mainParent);

		final sites: LockSites = new LockSites(graph, [for (f in files) f.file], plugin, file -> listsOf(file).pairs);
		final long: Array<String> = [];
		final taintHop: Map<String, CallEdge> = [];
		solveLongLocks(graph, sinkIds, listsOf, sites, long, taintHop);

		final violations: Array<Violation> = [];
		reportMainSinkCalls(graph, listsOf, sites, long, contexts, mainParent, violations);
		reportMalformedPairs(sets, violations);
		reportLockHeld(sites, listsOf, long, taintHop, contexts, violations);
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'moving the work off the main thread, or narrowing what the lock covers, is a concurrency design change no span'
			+ ' rewrite expresses';
	}

	/** `needs-config` without a `sinks` list — there is nothing to find — and `config-excluded` for a path under `exclude`. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return (config.stringListOption('thread-safety', 'sinks') ?? []).length == 0 ? 'needs-config' : scanSkipReason(file, config);
	}

	/**
	 * `config-excluded` for a path under `exclude`, the one file the graph leaves out: `exclude` says the code is no
	 * part of the analysis. A file with no `sinks` stays in the graph — its calls and `spawns` registrations decide the
	 * contexts of the files that do report.
	 */
	public function scanSkipReason(file: String, config: LintConfig): Null<String> {
		return pathExcluded(file, config.stringListOption('thread-safety', 'exclude') ?? []) ? 'config-excluded' : null;
	}

	/**
	 * Each file's `ChainLists`, one record per DISTINCT option set: `sets` receives them in the order
	 * their first file appears, so a single-chain run holds exactly one.
	 */
	private function listsByFile(
		files: Array<{ file: String, source: String }>, graph: CallGraph, sets: Array<ChainLists>
	): Map<String, ChainLists> {
		final bySignature: Map<String, ChainLists> = [];
		final byFile: Map<String, ChainLists> = [];
		for (entry in files) {
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final sinks: Array<String> = config.stringListOption('thread-safety', 'sinks') ?? [];
			final spawns: Array<String> = config.stringListOption('thread-safety', 'spawns') ?? [];
			final marshals: Array<String> = config.stringListOption('thread-safety', 'marshals') ?? [];
			final lockPairs: Array<String> = config.stringListOption('thread-safety', 'lockPairs') ?? [];
			final quietRoots: Array<String> = config.stringListOption('thread-safety', 'quietRoots') ?? [];
			final signature: String = [for (list in [sinks, spawns, marshals, lockPairs, quietRoots]) list.join('\n')].join('\t');
			final known: Null<ChainLists> = bySignature[signature];
			final lists: ChainLists = known ?? {
				reports: sinks.length > 0,
				sinkIds: matchAll(graph, sinks),
				spawnIds: matchAll(graph, spawns),
				marshalIds: matchAll(graph, marshals),
				quietIds: matchAll(graph, quietRoots),
				lockPairs: lockPairs,
				pairs: resolvePairs(graph, lockPairs)
			};
			if (known == null) {
				bySignature[signature] = lists;
				sets.push(lists);
			}
			byFile[entry.file] = lists;
		}
		return byFile;
	}

	/** The lists of the chain `file` sits under — every edge's file is one the graph was built from. */
	private static function listsOfFile(byFile: Map<String, ChainLists>, file: String): ChainLists {
		final lists: Null<ChainLists> = byFile[file];
		if (lists == null) throw new Exception('thread-safety: an edge sits in "$file", which no run file resolved a config for');
		return lists;
	}

	/** Union of `graph.matchIds` over `patterns`, deduplicated. */
	private static function matchAll(graph: CallGraph, patterns: Array<String>): Array<String> {
		final result: Array<String> = [];
		for (p in patterns) for (id in graph.matchIds(p)) if (!result.contains(id)) result.push(id);
		return result;
	}

	/** Every well-formed `lockPairs` entry as the graph's lock ids, each paired with the same type's unlock member. */
	private static function resolvePairs(graph: CallGraph, lockPairs: Array<String>): Array<LockPair> {
		final pairs: Array<LockPair> = [];
		for (entry in lockPairs) {
			final slash: Int = entry.lastIndexOf('/');
			if (slash <= 0) continue;
			for (lockId in graph.matchIds(entry.substring(0, slash))) {
				final dot: Int = lockId.lastIndexOf('.');
				if (dot > 0) pairs.push({ lockId: lockId, unlockId: lockId.substring(0, dot + 1) + entry.substring(slash + 1) });
			}
		}
		return pairs;
	}

	/**
	 * Fixed-point MAIN/BG propagation. Roots and caller-less nodes seed MAIN;
	 * spawn-received callbacks seed BG; marshal-received callbacks seed MAIN;
	 * every other edge propagates the source context. A thread entering a quiet root
	 * goes quiet (`enter`), and a callback registered from quiet code stays quiet (`carry`).
	 * `mainParent` records the edge that first carried MAIN into a node — the chain evidence.
	 */
	private static function propagateContexts(
		graph: CallGraph, listsOf: (String) -> ChainLists, quiet: Array<String>, contexts: Map<String, Int>,
		mainParent: Map<String, CallEdge>
	): Void {
		// noqa: complexity
		final queue: Array<String> = [];
		for (id => node in graph.nodes) if (!node.isExternal && graph.inEdges(id).length == 0) {
			contexts[id] = enter(quiet, id, CTX_MAIN);
			queue.push(id);
		}
		var qi: Int = 0;
		while (true) {
			while (qi < queue.length) {
				final id: String = queue[qi++];
				final ctx: Int = contexts[id] ?? 0;
				for (edge in graph.outEdges(id)) {
					final carried: Int = switch edge.kind {
						case Contains: 0;
						case Ref:
							final via: Null<String> = edge.via;
							if (via != null && listsOf(edge.file).spawnIds.contains(via))
								carry(ctx, CTX_BG, CTX_BG_QUIET);
							else if (via != null && listsOf(edge.file).marshalIds.contains(via))
								carry(ctx, CTX_MAIN, CTX_QUIET);
							else
								ctx;
						case _: ctx;
					};
					if (carried == 0) continue;
					final propagated: Int = enter(quiet, edge.to, carried);
					final old: Int = contexts[edge.to] ?? 0;
					final merged: Int = old | propagated;
					if (merged == old) continue;
					contexts[edge.to] = merged;
					if (old & CTX_MAIN == 0 && merged & CTX_MAIN != 0) mainParent[edge.to] = edge;
					queue.push(edge.to);
				}
			}
			// a node with no resolved callers and no context yet is ASSUMED main —
			// seeded INTO the worklist so the assumption reaches its callees (a
			// plain post-drain fill would silently miss their sink calls)
			var seeded: Bool = false;
			for (id => node in graph.nodes) if (!(node.isExternal || contexts.exists(id))) {
				contexts[id] = enter(quiet, id, CTX_MAIN);
				queue.push(id);
				seeded = true;
			}
			if (!seeded) break;
		}
	}

	/** The context `ctx` becomes on entering `id`: each thread goes quiet in a `quiet` root. */
	private static function enter(quiet: Array<String>, id: String, ctx: Int): Int {
		if (!quiet.contains(id)) return ctx;
		return (ctx & CTX_MAIN != 0 ? CTX_QUIET : 0) | (ctx & CTX_BG != 0 ? CTX_BG_QUIET : 0) | (ctx & CTX_QUIETED);
	}

	/** What a thread boundary hands a callback registered in `ctx`: `loud` from a path through no quiet root, `quieted` from one through one. */
	private static inline function carry(ctx: Int, loud: Int, quieted: Int): Int {
		return (ctx & CTX_LOUD != 0 ? loud : 0) | (ctx & CTX_QUIETED != 0 ? quieted : 0);
	}

	/**
	 * The long locks and the taint they imply, solved together: a call blocks when it reaches a sink, and a lock taken
	 * by a sink call blocks only when it is long, while a lock is long when a hold of it spans a call that blocks. Grows
	 * from the locks long on their own (`LockAcquire.leaks`, `LockSites.crossing`) until nothing changes.
	 */
	private static function solveLongLocks(
		graph: CallGraph, sinkIds: Array<String>, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>,
		taintHop: Map<String, CallEdge>
	): Void {
		for (lock in sites.crossing) if (!long.contains(lock)) long.push(lock);
		// a hold that outlives its function, or spans a call to nothing the graph knows, may last any time at all
		// a wrapper's own take leaks by design: whether it lasts is decided at each call of the wrapper, an acquire itself
		for (a in sites.acquires) if ((a.leaks && !a.delegated || a.blind && !a.uncontended) && a.lock != null && !long.contains(a.lock))
			long.push(a.lock);
		var grew: Bool = true;
		// the taint is rebuilt from scratch each round: a lock turning long adds sink edges anywhere in the graph, and the
		// rounds are bounded by the number of locks, so a worklist would buy little over the plain recompute
		while (grew) {
			taintHop.clear();
			collectTaint(graph, sinkIds, listsOf, sites, long, taintHop);
			grew = false;
			for (a in sites.acquires) {
				final lock: Null<String> = a.lock;
				if (lock == null || a.uncontended || long.contains(lock)) continue;
				if (!a.window.exists(e -> heldAcrossBlocking(e, listsOf, sites, long, taintHop))) continue;
				long.push(lock);
				grew = true;
			}
		}
	}

	/** Whether a hold spanning `edge` spans a blocking call: `edge` blocks itself, or reaches a sink — through anything but a lock. */
	private static function heldAcrossBlocking(
		edge: CallEdge, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>, taintHop: Map<String, CallEdge>
	): Bool {
		return blocks(edge, listsOf, sites, long) || taintHop.exists(edge.to) && !takesLock(edge, listsOf);
	}

	/** Whether `edge` is a call to a sink `lockPairs` names a lock of: one whose cost is the wait for that lock. */
	private static function takesLock(edge: CallEdge, listsOf: (String) -> ChainLists): Bool {
		final lists: ChainLists = listsOf(edge.file);
		return lists.sinkIds.contains(edge.to) && lists.pairs.exists(p -> p.lockId == edge.to);
	}

	/** Whether `edge` itself blocks: a sink call its site's chain names, one taking a lock only when the lock is long or unknown. */
	private static function blocks(edge: CallEdge, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>): Bool {
		if (!edge.kind.isInvocation() || !listsOf(edge.file).sinkIds.contains(edge.to)) return false;
		if (!takesLock(edge, listsOf)) return true;
		final lock: Null<String> = sites.lockOf(edge);
		return lock == null || long.contains(lock);
	}

	/**
	 * Reverse BFS from the blocking calls over the invocation edges (`EdgeKind.isInvocation`) — `taintHop[n]` is n's next
	 * edge toward a sink. A call taking a lock taints its caller by what the lock is (`blocks`), never through the lock
	 * primitive's own body: that body IS the wait.
	 */
	private static function collectTaint(
		graph: CallGraph, sinkIds: Array<String>, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>,
		taintHop: Map<String, CallEdge>
	): Void {
		final queue: Array<String> = [];
		// a node its call site's own chain names a sink is where a chain ENDS: a call to it blocks by that name (`blocks`)
		for (edge in graph.edges) if (
			sinkIds.contains(edge.to) && !taintHop.exists(edge.from) && !listsOf(edge.file).sinkIds.contains(edge.from)
			&& blocks(edge, listsOf, sites, long)
		) {
			taintHop[edge.from] = edge;
			queue.push(edge.from);
		}
		var qi: Int = 0;
		while (qi < queue.length) {
			final id: String = queue[qi++];
			for (edge in graph.inEdges(id)) if (edge.kind.isInvocation() && !taintHop.exists(edge.from) && !takesLock(edge, listsOf)) {
				// the edge leaves `from`'s body, so its file's chain is the one that says whether `from` is a sink
				if (listsOf(edge.file).sinkIds.contains(edge.from)) continue;
				taintHop[edge.from] = edge;
				queue.push(edge.from);
			}
		}
	}

	/** Finding (a): a MAIN-context function directly calls a sink — one taking a lock only when that lock is long or unknown. */
	private static function reportMainSinkCalls(
		graph: CallGraph, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>, contexts: Map<String, Int>,
		mainParent: Map<String, CallEdge>, violations: Array<Violation>
	): Void {
		for (edge in graph.edges) if (edge.kind.isInvocation()) {
			final lists: ChainLists = listsOf(edge.file);
			if (!blocks(edge, listsOf, sites, long)) continue;
			// a `marshals` function IS the thread boundary — its body dispatches
			// between contexts in ways the graph cannot see; sinks inside it are
			// the primitive's own machinery, not application-level main calls
			if (lists.marshalIds.contains(edge.from)) continue;
			final ctx: Int = contexts[edge.from] ?? 0;
			if (ctx & CTX_MAIN == 0) continue;
			final chain: String = mainChain(edge.from, mainParent);
			final also: String = ctx & (CTX_BG | CTX_BG_QUIET) != 0 ? ' (also reachable from a background thread)' : '';
			violations.push({
				file: edge.file,
				span: edge.span,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: 'main thread reaches blocking "${edge.to}"$also: $chain -> ${edge.to}'
			});
		}
	}

	/** Every malformed `lockPairs` entry of a reporting chain, once however many chains share it. */
	private static function reportMalformedPairs(sets: Array<ChainLists>, violations: Array<Violation>): Void {
		for (setIndex => lists in sets) for (pair in lists.lockPairs) {
			// a chain that reports nothing (`needs-config`) says nothing about its options either
			if (pair.lastIndexOf('/') > 0 || !lists.reports) continue;
			if (sets.slice(0, setIndex).exists(earlier -> earlier.reports && earlier.lockPairs.contains(pair))) continue;
			violations.push({
				file: '',
				span: null,
				rule: 'thread-safety',
				severity: Severity.Info,
				message: 'malformed lockPairs entry "$pair" — expected "<lock pattern>/<unlock member>"'
			});
		}
	}

	/**
	 * Finding (b): on some path of one function body a lock is held across a call that blocks. Reported for a lock the
	 * main thread takes somewhere (or one no sealed member names), since only then does the hold stall main; a hold in
	 * the owner's constructor before the object escapes stalls no one.
	 */
	private static function reportLockHeld(
		sites: LockSites, listsOf: (String) -> ChainLists, long: Array<String>, taintHop: Map<String, CallEdge>,
		contexts: Map<String, Int>, violations: Array<Violation>
	): Void {
		final seen: Array<String> = [];
		final mainTaken: Array<String> = [
			for (a in sites.acquires) if (a.lock != null && (contexts[a.edge.from] ?? 0) & CTX_MAIN != 0) a.lock
		];
		for (a in sites.acquires) {
			final lock: Null<String> = a.lock;
			if (a.uncontended || lock != null && !mainTaken.contains(lock)) continue;
			for (edge in a.window) {
				final span: Null<Span> = edge.span;
				if (span == null) continue;
				if (!heldAcrossBlocking(edge, listsOf, sites, long, taintHop)) continue;
				final evidence: String = blocks(edge, listsOf, sites, long) ? edge.to : taintChain(edge.to, taintHop);
				final message: String = '"${a.edge.from}" holds "${a.pair.lockId}" across a call that can block: $evidence';
				final key: String = '${edge.file}:${span.from}:$message';
				if (seen.contains(key)) continue;
				seen.push(key);
				violations.push({
					file: edge.file,
					span: span,
					rule: 'thread-safety',
					severity: Severity.Warning,
					message: message
				});
			}
		}
	}

	/** `root -> ... -> id` — how MAIN reached `id`, capped at CHAIN_CAP hops, cycle-safe (marshal ping-pong). */
	private static function mainChain(id: String, mainParent: Map<String, CallEdge>): String {
		final parts: Array<String> = [id];
		final visited: Array<String> = [id];
		var cursor: String = id;
		for (hops in 0...CHAIN_CAP) {
			final edge: Null<CallEdge> = mainParent[cursor];
			if (edge == null || visited.contains(edge.from)) break;
			parts.unshift(edge.from);
			visited.push(edge.from);
			cursor = edge.from;
		}
		final next: Null<CallEdge> = mainParent[cursor];
		if (next != null && !visited.contains(next.from)) parts.unshift('...');
		return parts.join(' -> ');
	}

	/** `id -> ... -> sink` — how `id` reaches a sink, capped at CHAIN_CAP hops. */
	private static function taintChain(id: String, taintHop: Map<String, CallEdge>): String {
		final parts: Array<String> = [id];
		var cursor: String = id;
		for (hops in 0...CHAIN_CAP) {
			final edge: Null<CallEdge> = taintHop[cursor];
			if (edge == null) break;
			parts.push(edge.to);
			cursor = edge.to;
		}
		if (taintHop[cursor] != null) parts.push('...');
		return parts.join(' -> ');
	}

	/** True when `file` contains one of `patterns` as a '/'-bounded path-segment run. */
	private static function pathExcluded(file: String, patterns: Array<String>): Bool {
		final wrapped: String = '/' + file.replace('\\', '/') + '/';
		for (p in patterns) {
			var trimmed: String = p;
			while (trimmed.startsWith('/')) trimmed = trimmed.substring(1);
			while (trimmed.endsWith('/')) trimmed = trimmed.substring(0, trimmed.length - 1);
			if (trimmed.length > 0 && wrapped.indexOf('/$trimmed/') != -1) return true;
		}
		return false;
	}

}
