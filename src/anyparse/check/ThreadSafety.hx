package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CallGraph;
import anyparse.query.CallGraph.CallEdge;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Config-driven thread-context analysis over the approximate `CallGraph` —
 * finds the two classic main-thread stall shapes:
 *
 *  (a) a MAIN-context function directly calling a configured blocking sink
 *      without an intervening thread spawn — "blocking operation on the main
 *      thread";
 *  (b) a function holding a configured lock across a call that transitively
 *      reaches a blocking sink — "lock held across blocking call" (the other
 *      thread then stalls main on the same lock).
 *
 * Context propagation: graph roots (no incoming edges) start MAIN — a UI app
 * runs everything on the main thread unless spawned off it. A callback passed
 * to a `spawns` target executes in a NEW thread (BG); one passed to a
 * `marshals` target executes on MAIN; any other callback inherits the
 * registrar's context. A node with no resolved callers is ASSUMED main — the
 * over-approximation a finder wants (candidates for human review, never a
 * silent miss). Sinks INSIDE a `marshals` function's own body are not
 * reported: the marshal primitive IS the thread boundary, and its internal
 * dispatch (context checks, queue pumping) is invisible to the graph.
 *
 * Configured per project in `apqlint.json` (the rule is inert without it):
 *
 *     "thread-safety": {
 *         "sinks":     ["app.Mutex.lock", "Sys.sleep", "sys.io.File.*"],
 *         "spawns":    ["app.Worker.spawn", "Thread.create"],
 *         "marshals":  ["app.Worker.runOnMain"],
 *         "lockPairs": ["app.Mutex.lock/unlock", "RwLock.lock/unlock"],
 *         "exclude":   ["test"]
 *     }
 *
 * `exclude` drops files whose path contains an entry as a '/'-bounded
 * segment run BEFORE the graph is built — test code exercising blocking
 * calls on its own thread would otherwise pollute every context.
 *
 * Patterns are matched by their last two dot-segments (`SymbolIndex` models no
 * packages); `Type.*` covers every recorded member of a type. A `lockPairs`
 * entry is `<lock pattern>/<unlock member name>` on the same type.
 */
@:nullSafety(Strict)
final class ThreadSafety implements Check {

	private static inline final CTX_MAIN: Int = 1;

	private static inline final CTX_BG: Int = 2;

	private static inline final CHAIN_CAP: Int = 8;

	public function new() {}

	public function id(): String {
		return 'thread-safety';
	}

	public function description(): String {
		return 'main-thread-reachable blocking calls and locks held across blocking calls (config-driven)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		if (files.length == 0) return [];
		final config: LintConfig = LintConfig.discover(files[0].file);
		final sinks: Array<String> = config.stringListOption('thread-safety', 'sinks') ?? [];
		if (sinks.length == 0) return [];
		final spawns: Array<String> = config.stringListOption('thread-safety', 'spawns') ?? [];
		final marshals: Array<String> = config.stringListOption('thread-safety', 'marshals') ?? [];
		final lockPairs: Array<String> = config.stringListOption('thread-safety', 'lockPairs') ?? [];

		final excludes: Array<String> = config.stringListOption('thread-safety', 'exclude') ?? [];
		final scanned: Array<{ file: String, source: String }> = excludes.length == 0
			? files
			: files.filter(f -> !pathExcluded(f.file, excludes));
		if (scanned.length == 0) return [];
		final graph: CallGraph = CallGraph.build(scanned, plugin);
		final sinkIds: Array<String> = matchAll(graph, sinks);
		if (sinkIds.length == 0) return [];
		final spawnIds: Array<String> = matchAll(graph, spawns);
		final marshalIds: Array<String> = matchAll(graph, marshals);

		final contexts: Map<String, Int> = [];
		final mainParent: Map<String, CallEdge> = [];
		propagateContexts(graph, spawnIds, marshalIds, contexts, mainParent);

		final taintHop: Map<String, CallEdge> = [];
		collectTaint(graph, sinkIds, taintHop);

		final violations: Array<Violation> = [];
		reportMainSinkCalls(graph, sinkIds, marshalIds, contexts, mainParent, violations);
		reportLockHeld(graph, lockPairs, sinkIds, taintHop, violations);
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Union of `graph.matchIds` over `patterns`, deduplicated. */
	private static function matchAll(graph: CallGraph, patterns: Array<String>): Array<String> {
		final result: Array<String> = [];
		for (p in patterns) for (id in graph.matchIds(p)) if (!result.contains(id)) result.push(id);
		return result;
	}

	/**
	 * Fixed-point MAIN/BG propagation. Roots and caller-less nodes seed MAIN;
	 * spawn-received callbacks seed BG; marshal-received callbacks seed MAIN;
	 * every other edge propagates the source context. `mainParent` records the
	 * edge that first carried MAIN into a node — the chain evidence.
	 */
	private static function propagateContexts(
		graph: CallGraph, spawnIds: Array<String>, marshalIds: Array<String>, contexts: Map<String, Int>,
		mainParent: Map<String, CallEdge>
	): Void {
		final queue: Array<String> = [];
		for (id => node in graph.nodes) {
			if (node.isExternal) continue;
			if (graph.inEdges(id).length == 0) {
				contexts[id] = CTX_MAIN;
				queue.push(id);
			}
		}
		var qi: Int = 0;
		while (true) {
			while (qi < queue.length) {
				final id: String = queue[qi++];
				final ctx: Int = contexts[id] ?? 0;
				for (edge in graph.outEdges(id)) {
					final propagated: Int = switch edge.kind {
						case Contains: 0;
						case Ref:
							final via: Null<String> = edge.via;
							if (via != null && spawnIds.contains(via))
								CTX_BG;
							else if (via != null && marshalIds.contains(via))
								CTX_MAIN;
							else
								ctx;
						case _: ctx;
					};
					if (propagated == 0) continue;
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
			for (id => node in graph.nodes) {
				if (node.isExternal || contexts.exists(id)) continue;
				contexts[id] = CTX_MAIN;
				queue.push(id);
				seeded = true;
			}
			if (!seeded) break;
		}
	}

	/** Reverse BFS from the sinks over Call/New/Virtual — `taintHop[n]` is n's next edge toward a sink. */
	private static function collectTaint(graph: CallGraph, sinkIds: Array<String>, taintHop: Map<String, CallEdge>): Void {
		final queue: Array<String> = sinkIds.copy();
		var qi: Int = 0;
		while (qi < queue.length) {
			final id: String = queue[qi++];
			for (edge in graph.inEdges(id)) {
				if (edge.kind != Call && edge.kind != New && edge.kind != Virtual) continue;
				if (sinkIds.contains(edge.from) || taintHop.exists(edge.from)) continue;
				taintHop[edge.from] = edge;
				queue.push(edge.from);
			}
		}
	}

	/** Finding (a): a MAIN-context function directly calls a sink. */
	private static function reportMainSinkCalls(
		graph: CallGraph, sinkIds: Array<String>, marshalIds: Array<String>, contexts: Map<String, Int>, mainParent: Map<String, CallEdge>,
		violations: Array<Violation>
	): Void {
		for (edge in graph.edges) {
			if (edge.kind != Call && edge.kind != New && edge.kind != Virtual) continue;
			if (!sinkIds.contains(edge.to)) continue;
			// a `marshals` function IS the thread boundary — its body dispatches
			// between contexts in ways the graph cannot see; sinks inside it are
			// the primitive's own machinery, not application-level main calls
			if (marshalIds.contains(edge.from)) continue;
			final ctx: Int = contexts[edge.from] ?? 0;
			if (ctx & CTX_MAIN == 0) continue;
			final chain: String = mainChain(edge.from, mainParent);
			final also: String = ctx & CTX_BG != 0 ? ' (also reachable from a background thread)' : '';
			violations.push({
				file: edge.file,
				span: edge.span,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: 'main thread reaches blocking "${edge.to}"$also: $chain -> ${edge.to}',
			});
		}
	}

	/**
	 * Finding (b): between a lock call and the SAME TYPE's unlock call inside
	 * one function body (source order), a call transitively reaches a sink.
	 * Receiver identity is not tracked — same-type pairing is the
	 * over-approximation.
	 */
	private static function reportLockHeld(
		graph: CallGraph, lockPairs: Array<String>, sinkIds: Array<String>, taintHop: Map<String, CallEdge>, violations: Array<Violation>
	): Void {
		final seen: Array<String> = [];
		for (pair in lockPairs) {
			final slash: Int = pair.lastIndexOf('/');
			if (slash <= 0) {
				violations.push({
					file: '',
					span: null,
					rule: 'thread-safety',
					severity: Severity.Info,
					message: 'malformed lockPairs entry "$pair" — expected "<lock pattern>/<unlock member>"',
				});
				continue;
			}
			final lockIds: Array<String> = graph.matchIds(pair.substring(0, slash));
			final unlockMember: String = pair.substring(slash + 1);
			for (lockId in lockIds) {
				final dot: Int = lockId.lastIndexOf('.');
				if (dot <= 0) continue;
				final unlockId: String = lockId.substring(0, dot + 1) + unlockMember;
				for (lockEdge in graph.inEdges(lockId)) {
					if (lockEdge.kind != Call) continue;
					final lockSpan: Null<Span> = lockEdge.span;
					if (lockSpan == null) continue;
					final windowEnd: Null<Int> = closingUnlockFrom(graph, lockEdge, unlockId);
					if (windowEnd == null) continue;
					for (edge in graph.outEdges(lockEdge.from)) {
						if (edge.kind != Call && edge.kind != New && edge.kind != Virtual) continue;
						// same-simple-name types merge into one graph node — only
						// edges from the SAME FILE belong to this lock's body window
						if (edge.file != lockEdge.file) continue;
						final span: Null<Span> = edge.span;
						if (span == null || span.from <= lockSpan.from || span.from >= windowEnd) continue;
						// the closing unlock is excluded; a SECOND lock call inside
						// the window is a nested re-acquire and stays reportable
						if (edge.to == unlockId) continue;
						final direct: Bool = sinkIds.contains(edge.to);
						if (!direct && !taintHop.exists(edge.to)) continue;
						final evidence: String = direct ? edge.to : taintChain(edge.to, taintHop);
						final message: String = '"${lockEdge.from}" holds "$lockId" across a call that can block: $evidence';
						final key: String = '${edge.file}:${span.from}:$message';
						if (seen.contains(key)) continue;
						seen.push(key);
						violations.push({
							file: edge.file,
							span: span,
							rule: 'thread-safety',
							severity: Severity.Warning,
							message: message,
						});
					}
				}
			}
		}
	}

	/** Span start of the first same-function unlock call after `lockEdge`, or null when the lock is not closed in this body. */
	private static function closingUnlockFrom(graph: CallGraph, lockEdge: CallEdge, unlockId: String): Null<Int> {
		final lockSpan: Null<Span> = lockEdge.span;
		if (lockSpan == null) return null;
		var best: Null<Int> = null;
		for (edge in graph.outEdges(lockEdge.from)) {
			if (edge.kind != Call || edge.to != unlockId) continue;
			if (edge.file != lockEdge.file) continue;
			final span: Null<Span> = edge.span;
			if (span == null || span.from <= lockSpan.from) continue;
			if (best == null || span.from < best) best = span.from;
		}
		return best;
	}

	/** `root -> ... -> id` — how MAIN reached `id`, capped at CHAIN_CAP hops, cycle-safe (marshal ping-pong). */
	private static function mainChain(id: String, mainParent: Map<String, CallEdge>): String {
		final parts: Array<String> = [id];
		final visited: Array<String> = [id];
		var cursor: String = id;
		var hops: Int = 0;
		while (hops < CHAIN_CAP) {
			final edge: Null<CallEdge> = mainParent[cursor];
			if (edge == null || visited.contains(edge.from)) break;
			parts.unshift(edge.from);
			visited.push(edge.from);
			cursor = edge.from;
			hops++;
		}
		final next: Null<CallEdge> = mainParent[cursor];
		if (next != null && !visited.contains(next.from)) parts.unshift('...');
		return parts.join(' -> ');
	}

	/** `id -> ... -> sink` — how `id` reaches a sink, capped at CHAIN_CAP hops. */
	private static function taintChain(id: String, taintHop: Map<String, CallEdge>): String {
		final parts: Array<String> = [id];
		var cursor: String = id;
		var hops: Int = 0;
		while (hops < CHAIN_CAP) {
			final edge: Null<CallEdge> = taintHop[cursor];
			if (edge == null) break;
			parts.push(edge.to);
			cursor = edge.to;
			hops++;
		}
		if (taintHop[cursor] != null) parts.push('...');
		return parts.join(' -> ');
	}

	/** True when `file` contains one of `patterns` as a '/'-bounded path-segment run. */
	private static function pathExcluded(file: String, patterns: Array<String>): Bool {
		final wrapped: String = '/' + StringTools.replace(file, '\\', '/') + '/';
		for (p in patterns) {
			var trimmed: String = p;
			while (StringTools.startsWith(trimmed, '/')) trimmed = trimmed.substring(1);
			while (StringTools.endsWith(trimmed, '/')) trimmed = trimmed.substring(0, trimmed.length - 1);
			if (trimmed.length > 0 && wrapped.indexOf('/' + trimmed + '/') != -1) return true;
		}
		return false;
	}

}
