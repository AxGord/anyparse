package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.GraphScoped;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * One `apqlint.json` chain's `thread-safety` lists: the three name lists resolved to graph ids, the
 * lock pairs as written (`reportLockHeld` parses them).
 */
private typedef ChainLists = {
	final sinkIds: Array<String>;
	final spawnIds: Array<String>;
	final marshalIds: Array<String>;
	final lockPairs: Array<String>;
}

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
final class ThreadSafety implements Check implements ConfigAware implements NoAutofix implements GraphScoped {

	private static inline final CTX_MAIN: Int = 1;
	private static inline final CTX_BG: Int = 2;
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
	 * ONE graph over every file of the run but an `exclude`d one, whatever config chains they span — a file whose chain
	 * names no `sinks` included, since its calls and registrations shape the other files' contexts — and each SITE
	 * judged by the chain of its own file: a call is a sink call when its call site's chain lists that sink, a callback
	 * is spawned or marshalled when the registering site's chain lists that target, a lock window opens under its file's
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
		propagateContexts(graph, listsOf, contexts, mainParent);

		final taintHop: Map<String, CallEdge> = [];
		collectTaint(graph, sinkIds, listsOf, taintHop);

		final violations: Array<Violation> = [];
		reportMainSinkCalls(graph, listsOf, contexts, mainParent, violations);
		reportLockHeld(graph, sets, listsOf, taintHop, violations);
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
			final signature: String = [for (list in [sinks, spawns, marshals, lockPairs]) list.join('\n')].join('\t');
			final known: Null<ChainLists> = bySignature[signature];
			final lists: ChainLists = known ?? {
				sinkIds: matchAll(graph, sinks),
				spawnIds: matchAll(graph, spawns),
				marshalIds: matchAll(graph, marshals),
				lockPairs: lockPairs
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

	/**
	 * Fixed-point MAIN/BG propagation. Roots and caller-less nodes seed MAIN;
	 * spawn-received callbacks seed BG; marshal-received callbacks seed MAIN;
	 * every other edge propagates the source context. `mainParent` records the
	 * edge that first carried MAIN into a node — the chain evidence.
	 */
	private static function propagateContexts(
		graph: CallGraph, listsOf: (String) -> ChainLists, contexts: Map<String, Int>, mainParent: Map<String, CallEdge>
	): Void {
		// noqa: complexity
		final queue: Array<String> = [];
		for (id => node in graph.nodes) if (!node.isExternal && graph.inEdges(id).length == 0) {
			contexts[id] = CTX_MAIN;
			queue.push(id);
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
							if (via != null && listsOf(edge.file).spawnIds.contains(via))
								CTX_BG;
							else if (via != null && listsOf(edge.file).marshalIds.contains(via))
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
			for (id => node in graph.nodes) if (!(node.isExternal || contexts.exists(id))) {
				contexts[id] = CTX_MAIN;
				queue.push(id);
				seeded = true;
			}
			if (!seeded) break;
		}
	}

	/**
	 * Reverse BFS from the sinks over the invocation edges (`EdgeKind.isInvocation`) — `taintHop[n]` is n's next edge toward a sink.
	 * `sinkIds` is the union over every chain: a call taints its caller when the call site's own chain names the callee a
	 * sink, or when the callee is itself tainted.
	 */
	private static function collectTaint(
		graph: CallGraph, sinkIds: Array<String>, listsOf: (String) -> ChainLists, taintHop: Map<String, CallEdge>
	): Void {
		final queue: Array<String> = sinkIds.copy();
		var qi: Int = 0;
		while (qi < queue.length) {
			final id: String = queue[qi++];
			for (edge in graph.inEdges(id)) if (edge.kind.isInvocation()) {
				// the edge leaves `from`'s body, so its file's chain is the one that says whether `from` is a sink
				final lists: ChainLists = listsOf(edge.file);
				if (lists.sinkIds.contains(edge.from) || taintHop.exists(edge.from)) continue;
				if (!(lists.sinkIds.contains(id) || taintHop.exists(id))) continue;
				taintHop[edge.from] = edge;
				queue.push(edge.from);
			}
		}
	}

	/** Finding (a): a MAIN-context function directly calls a sink. */
	private static function reportMainSinkCalls(
		graph: CallGraph, listsOf: (String) -> ChainLists, contexts: Map<String, Int>, mainParent: Map<String, CallEdge>,
		violations: Array<Violation>
	): Void {
		for (edge in graph.edges) if (edge.kind.isInvocation()) {
			final lists: ChainLists = listsOf(edge.file);
			if (!lists.sinkIds.contains(edge.to)) continue;
			// a `marshals` function IS the thread boundary — its body dispatches
			// between contexts in ways the graph cannot see; sinks inside it are
			// the primitive's own machinery, not application-level main calls
			if (lists.marshalIds.contains(edge.from)) continue;
			final ctx: Int = contexts[edge.from] ?? 0;
			if (ctx & CTX_MAIN == 0) continue;
			final chain: String = mainChain(edge.from, mainParent);
			final also: String = ctx & CTX_BG != 0 ? ' (also reachable from a background thread)' : '';
			violations.push({
				file: edge.file,
				span: edge.span,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: 'main thread reaches blocking "${edge.to}"$also: $chain -> ${edge.to}'
			});
		}
	}

	/**
	 * Finding (b): between a lock call and the SAME TYPE's unlock call inside
	 * one function body (source order), a call transitively reaches a sink.
	 * Receiver identity is not tracked — same-type pairing is the
	 * over-approximation. Each chain's `lockPairs` open windows only in its own files; a malformed
	 * entry several chains share is reported once.
	 */
	private static function reportLockHeld(
		graph: CallGraph, sets: Array<ChainLists>, listsOf: (String) -> ChainLists, taintHop: Map<String, CallEdge>,
		violations: Array<Violation>
	): Void {
		// noqa: complexity
		final seen: Array<String> = [];
		for (setIndex => lists in sets) for (pair in lists.lockPairs) {
			final slash: Int = pair.lastIndexOf('/');
			if (slash <= 0) {
				if (sets.slice(0, setIndex).exists(earlier -> earlier.lockPairs.contains(pair))) continue;
				violations.push({
					file: '',
					span: null,
					rule: 'thread-safety',
					severity: Severity.Info,
					message: 'malformed lockPairs entry "$pair" — expected "<lock pattern>/<unlock member>"'
				});
				continue;
			}
			final lockIds: Array<String> = graph.matchIds(pair.substring(0, slash));
			final unlockMember: String = pair.substring(slash + 1);
			for (lockId in lockIds) {
				final dot: Int = lockId.lastIndexOf('.');
				if (dot <= 0) continue;
				final unlockId: String = lockId.substring(0, dot + 1) + unlockMember;
				for (lockEdge in graph.inEdges(lockId)) if (lockEdge.kind == Call && listsOf(lockEdge.file) == lists) {
					final lockSpan: Null<Span> = lockEdge.span;
					if (lockSpan == null) continue;
					final windowEnd: Null<Int> = closingUnlockFrom(graph, lockEdge, unlockId);
					if (windowEnd == null) continue;
					for (edge in graph.outEdges(lockEdge.from)) {
						if (!edge.kind.isInvocation()) continue;
						// same-simple-name types merge into one graph node — only
						// edges from the SAME FILE belong to this lock's body window
						if (edge.file != lockEdge.file) continue;
						final span: Null<Span> = edge.span;
						if (span == null || span.from <= lockSpan.from || span.from >= windowEnd) continue;
						// the closing unlock is excluded; a SECOND lock call inside
						// the window is a nested re-acquire and stays reportable
						if (edge.to == unlockId) continue;
						final direct: Bool = lists.sinkIds.contains(edge.to);
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
							message: message
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
