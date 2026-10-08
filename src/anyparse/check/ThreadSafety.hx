package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.GraphScoped;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.LockSites.LockPair;
import anyparse.check.LockTaint.ChainLists;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * Config-driven thread-context analysis over the approximate `CallGraph` — finds the two classic main-thread stalls:
 * (a) a MAIN-context function calling a configured blocking sink; (b) a function holding a configured lock across a
 * call that transitively reaches a sink, while the main thread takes that lock somewhere — and the two ways a lock
 * hangs a thread for good: (c) a lock still held where an exception leaves the function that took it; (d) two locks
 * taken in opposite orders on the main thread and on a background one (`LockOrder`).
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
 *         "reentrantLocks": ["app.Mutex.lock"],
 *         "throwers":  ["sys.FileSystem.createDirectory", "sys.io.File.saveContent"],
 *         "exclude":   ["test"]
 *     }
 *
 * `exclude` drops files whose path contains an entry as a '/'-bounded segment run BEFORE the graph is built. Patterns
 * are matched by their last two dot-segments (`SymbolIndex` models no packages); `Type.*` covers every recorded member
 * of a type. A `lockPairs` entry is `<lock pattern>/<unlock member name>` on the same type. A call of a lock WRAPPER
 * (`LockSites`) takes or gives back its lock with no entry of its own. A `quietRoots` function — a shutdown or crash
 * handler that blocks on purpose — makes the main thread QUIET in it and in what it calls directly, but only while no
 * loud main-thread code calls it (`settleContexts`), and never in a callback it registers or a thread it spawns: those
 * run later, loud. A take listed in `reentrantLocks` is one the holding thread may repeat without waiting: inside a
 * hold of a NAMED lock of that kind, taking the SAME OBJECT's lock again (`LockTaint`) blocks nothing. Re-entrance is
 * never assumed: a lock kind not listed, a lock no member names, or a take on another object keeps it a blocking call.
 * A `throwers` entry is a call that raises on a real runtime condition (`ThrowReach`): with none listed, only a `throw`
 * in the holding body itself leaves a lock held.
 *
 * Findings are grouped: one per hold, at its first blocking call or its first escape, one per main-thread sink call
 * site, and one per pair of locks taken in both orders.
 */
@:nullSafety(Strict)
final class ThreadSafety implements Check implements ConfigAware implements NoAutofix implements GraphScoped {

	private static inline final CTX_MAIN: Int = 1;
	private static inline final CTX_BG: Int = 2;

	/** The main thread on a path through a `quietRoots` function: reached, but never reported. */
	private static inline final CTX_QUIET: Int = 4;

	private static inline final CHAIN_CAP: Int = 8;
	private static inline final EVIDENCE_CAP: Int = 8;

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
		return 'main-thread-reachable blocking calls, locks held across blocking calls or left held by a throw, and lock-order'
			+ ' inversions between threads (config-driven)';
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
		settleContexts(graph, listsOf, [
			for (id => node in graph.nodes) if (byFile[node.file]?.quietIds.contains(id) == true) id
		], contexts, mainParent);

		final trees: FunctionTrees = new FunctionTrees(graph, plugin);
		final throws: ThrowReach = new ThrowReach(graph, plugin.refShape(), file -> listsOf(file).throwerIds, trees);
		final sites: LockSites = new LockSites(graph, [for (f in files) f.file], plugin, file -> listsOf(file).pairs, throws, trees);
		final long: Array<String> = [];
		final taints: LockTaint = new LockTaint(graph, sinkIds, listsOf, sites, long);
		solveLongLocks(sites, long, taints);

		final violations: Array<Violation> = [];
		reportMainSinkCalls(graph, taints, contexts, mainParent, violations);
		reportMalformedPairs(sets, violations);
		reportLockHeld(sites, taints, contexts, violations);
		reportThrowHeld(sites, throws, violations);
		final order: LockOrder = new LockOrder(graph, sites.acquires.concat(sites.helperHolds));
		for (v in order.report(contexts, (e, ctx) -> callbackContext(e, listsOf(e.file), ctx), CTX_MAIN | CTX_QUIET, CTX_BG, CHAIN_CAP))
			violations.push(v);
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
			final reentrant: Array<String> = config.stringListOption('thread-safety', 'reentrantLocks') ?? [];
			final throwers: Array<String> = config.stringListOption('thread-safety', 'throwers') ?? [];
			final signature: String = [
				for (list in [sinks, spawns, marshals, lockPairs, quietRoots, reentrant, throwers]) list.join('\n')
			].join('\t');
			final known: Null<ChainLists> = bySignature[signature];
			final lists: ChainLists = known ?? {
				reports: sinks.length > 0,
				sinkIds: matchAll(graph, sinks),
				spawnIds: matchAll(graph, spawns),
				marshalIds: matchAll(graph, marshals),
				quietIds: matchAll(graph, quietRoots),
				reentrantIds: matchAll(graph, reentrant),
				throwerIds: matchAll(graph, throwers),
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
	 * The context a callback `edge` registers from `ctx` runs in: a `spawns` target's BG, a `marshals` target's MAIN,
	 * any other the registrar's own — quiet never among them: a callback runs later, from whatever invokes it.
	 */
	private static function callbackContext(edge: CallEdge, lists: ChainLists, ctx: Int): Int {
		final via: Null<String> = edge.via;
		final loud: Int = (ctx & CTX_QUIET != 0 ? CTX_MAIN : 0) | (ctx & (CTX_MAIN | CTX_BG));
		return if (via != null && lists.spawnIds.contains(via))
			CTX_BG
		else if (via != null && lists.marshalIds.contains(via))
			CTX_MAIN
		else
			loud;
	}

	/**
	 * `propagateContexts` with the `quiet` roots only the main thread never enters loud: a root some invocation reaches
	 * from loud MAIN code is dropped, and the contexts are solved again until none is. A root's registration as a
	 * callback (a `Ref`, as a handler is) does not make it loud: declaring how such a callback runs is what the list is for.
	 */
	private static function settleContexts(
		graph: CallGraph, listsOf: (String) -> ChainLists, quiet: Array<String>, contexts: Map<String, Int>,
		mainParent: Map<String, CallEdge>
	): Void {
		var roots: Array<String> = quiet;
		while (true) {
			contexts.clear();
			mainParent.clear();
			propagateContexts(graph, listsOf, roots, contexts, mainParent);
			final loud: Array<String> = [
				for (q in roots) if (graph.inEdges(q).exists(e -> e.kind.isInvocation() && (contexts[e.from] ?? 0) & CTX_MAIN != 0)) q
			];
			if (loud.length == 0) return;
			roots = roots.filter(q -> !loud.contains(q));
		}
	}

	/** The context `ctx` becomes on entering `id`: the main thread goes quiet in a `quiet` root. */
	private static function enter(quiet: Array<String>, id: String, ctx: Int): Int {
		return quiet.contains(id) && ctx & CTX_MAIN != 0 ? (ctx & ~CTX_MAIN) | CTX_QUIET : ctx;
	}

	/**
	 * Fixed-point MAIN/BG propagation. Roots and caller-less nodes seed MAIN;
	 * spawn-received callbacks seed BG; marshal-received callbacks seed MAIN;
	 * every other edge propagates the source context. The main thread entering a quiet
	 * root goes quiet (`enter`) and stays so through direct calls; callbacks never inherit it.
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
						case Ref: callbackContext(edge, listsOf(edge.file), ctx);
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

	/**
	 * The long locks and the taint they imply, solved together: a call blocks when it reaches a sink, and a lock taken
	 * by a sink call blocks only when it is long, while a lock is long when a hold of it spans a call that blocks. Grows
	 * from the locks long on their own (`LockAcquire.leaks`, `LockSites.crossing`) until nothing changes.
	 */
	private static function solveLongLocks(sites: LockSites, long: Array<String>, taints: LockTaint): Void {
		for (lock in sites.crossing) if (!long.contains(lock)) long.push(lock);
		// a hold that outlives its function, or spans a call to nothing the graph knows, may last any time at all
		// a wrapper's own take leaks by design: whether it lasts is decided at each call of the wrapper, an acquire itself
		for (a in sites.acquires) if ((a.leaks && !a.delegated || a.blind && !a.uncontended) && a.lock != null && !long.contains(a.lock))
			long.push(a.lock);
		var grew: Bool = true;
		// the taint is rebuilt from scratch each round: a lock turning long adds sink edges anywhere in the graph, and the
		// rounds are bounded by the number of locks, so a worklist would buy little over the plain recompute
		while (grew) {
			taints.clear();
			grew = false;
			for (a in sites.acquires) {
				final lock: Null<String> = a.lock;
				if (lock == null || a.uncontended || long.contains(lock)) continue;
				final held: Null<String> = taints.reentrantHeld(a);
				if (!a.window.exists(e -> taints.heldAcrossBlocking(e, held))) continue;
				long.push(lock);
				grew = true;
			}
		}
	}

	/**
	 * Finding (a): a MAIN-context function directly calls a sink — one taking a lock only when that lock is long or
	 * unknown. One finding per call site, naming every sink a dispatch there may reach.
	 */
	private static function reportMainSinkCalls(
		graph: CallGraph, taints: LockTaint, contexts: Map<String, Int>, mainParent: Map<String, CallEdge>, violations: Array<Violation>
	): Void {
		final targets: Map<String, Array<String>> = [];
		final order: Array<{ key: String, edge: CallEdge }> = [];
		for (edge in graph.edges) if (edge.kind.isInvocation()) {
			if (!taints.blocks(edge, null)) continue;
			// a `marshals` function IS the thread boundary — its body dispatches
			// between contexts in ways the graph cannot see; sinks inside it are
			// the primitive's own machinery, not application-level main calls
			if (taints.listsOf(edge.file).marshalIds.contains(edge.from)) continue;
			final ctx: Int = contexts[edge.from] ?? 0;
			if (ctx & CTX_MAIN == 0) continue;
			final key: String = '${edge.file}:${edge.span?.from ?? -1}:${edge.from}';
			final known: Null<Array<String>> = targets[key];
			if (known == null) {
				targets[key] = [edge.to];
				order.push({ key: key, edge: edge });
			} else if (!known.contains(edge.to)) {
				known.push(edge.to);
			}
		}
		for (site in order) {
			final edge: CallEdge = site.edge;
			final ctx: Int = contexts[edge.from] ?? 0;
			final sinks: Array<String> = targets[site.key] ?? [edge.to];
			final named: String = [for (t in sinks) '"$t"'].join(' / ');
			final also: String = ctx & CTX_BG != 0 ? ' (also reachable from a background thread)' : '';
			violations.push({
				file: edge.file,
				span: edge.span,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: 'main thread reaches blocking $named$also: ${mainChain(edge.from, mainParent)} -> ${sinks.join(' / ')}'
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
	 * Finding (b): on some path of one function body a lock is held across calls that block — one finding per hold,
	 * anchored at its first blocking call and naming the lock object (the pair's take member for a lock no member
	 * names). Reported for a lock the main thread takes somewhere (or one no sealed member names), since only then does
	 * the hold stall main; a hold in the owner's constructor before the object escapes stalls no one.
	 */
	private static function reportLockHeld(
		sites: LockSites, taints: LockTaint, contexts: Map<String, Int>, violations: Array<Violation>
	): Void {
		final seen: Array<String> = [];
		final mainTaken: Array<String> = [
			for (a in sites.acquires) if (a.lock != null && (contexts[a.edge.from] ?? 0) & CTX_MAIN != 0) a.lock
		];
		for (a in sites.acquires) {
			final lock: Null<String> = a.lock;
			if (a.uncontended || lock != null && !mainTaken.contains(lock)) continue;
			final held: Null<String> = taints.reentrantHeld(a);
			final blocking: Array<CallEdge> = [for (e in a.window) if (e.span != null && taints.heldAcrossBlocking(e, held)) e];
			if (blocking.length == 0) continue;
			blocking.sort((x, y) -> (x.span?.from ?? 0) - (y.span?.from ?? 0));
			final calls: String = blocking.length == 1 ? 'a call' : '${blocking.length} calls';
			final message: String = '"${a.edge.from}" holds "${lock ?? a.pair.lockId}" across $calls that can block: '
				+ evidenceOf(blocking, held, taints);
			final anchor: CallEdge = blocking[0];
			final key: String = '${anchor.file}:${anchor.span?.from}:$message';
			if (seen.contains(key)) continue;
			seen.push(key);
			violations.push({
				file: anchor.file,
				span: anchor.span,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: message
			});
		}
	}

	/**
	 * Finding (c): on some path of one function body a lock may still be held where an exception leaves the body — a
	 * `throw`, or a call `ThrowReach` knows may raise, with no `catch` of the body around it — so nothing on that path
	 * gives it back and the next take waits forever. One finding per hold, at its
	 * first escape, the holds a multi-lock helper opens in its caller included.
	 */
	private static function reportThrowHeld(sites: LockSites, throws: ThrowReach, violations: Array<Violation>): Void {
		final seen: Array<String> = [];
		// an escape leaks the hold, so none is the owner's constructor's (`LockAcquire.uncontended`)
		for (a in sites.acquires.concat(sites.helperHolds)) if (a.escapes.length > 0) {
			final evidence: Array<String> = [];
			for (escape in a.escapes) {
				final raiser: Null<CallEdge> = escape.raiser;
				final shown: String = raiser == null ? 'a throw' : elided(throws.chain(raiser), CHAIN_CAP);
				if (!evidence.contains(shown)) evidence.push(shown);
			}
			final message: String = '"${a.edge.from}" leaves "${a.lock ?? a.pair.lockId}" held when it throws, with no catch to'
				+ ' release it: ${capped(evidence)}';
			final anchor: Span = a.escapes[0].span;
			final key: String = '${a.edge.file}:${anchor.from}:$message';
			if (seen.contains(key)) continue;
			seen.push(key);
			violations.push({
				file: a.edge.file,
				span: anchor,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: message
			});
		}
	}

	/** What each of `blocking` reaches, distinct, capped (`capped`). */
	private static function evidenceOf(blocking: Array<CallEdge>, held: Null<String>, taints: LockTaint): String {
		final evidence: Array<String> = [];
		for (e in blocking) {
			final shown: String = if (taints.blocks(e, held))
				e.to
			else if (taints.hops(held).exists(e.to))
				taintChain(e.to, taints.hops(held))
			else
				'${e.to} (the held lock, on another object)';
			if (!evidence.contains(shown)) evidence.push(shown);
		}
		return capped(evidence);
	}

	/**
	 * `parts` joined as a call chain, at most `cap` of them: the head says where the chain leaves its function, the
	 * last two what it ends in.
	 */
	public static function elided(parts: Array<String>, cap: Int): String {
		return (parts.length <= cap ? parts : parts.slice(0, cap - 2).concat(['...']).concat(parts.slice(-2))).join(' -> ');
	}

	/** `evidence` joined, the first `EVIDENCE_CAP` named and the rest counted. */
	private static function capped(evidence: Array<String>): String {
		final more: Int = evidence.length - EVIDENCE_CAP;
		return evidence.slice(0, EVIDENCE_CAP).join('; ') + (more > 0 ? '; +$more more' : '');
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
