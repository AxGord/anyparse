package anyparse.check;

import anyparse.query.CallGraph;

using Lambda;

/**
 * One way a thread runs a function: `id` under `valuation` (`EdgeConditions`), on the context bits `ctx`, MAIN first
 * carried in from `parent` (null for a state seeded MAIN).
 */
private typedef ThreadState = {
	final id: String;
	final valuation: String;
	var ctx: Int;
	var parent: Null<ThreadState>;
}

/**
 * The contexts a thread may run each function in, solved over STATES — a function and the valuation of its tracked
 * parameters (`EdgeConditions`) — so a call a condition rules out on a path carries nothing along it: a call under
 * `if (!batch)` reached only with `batch = true`, the async branch of a main-thread check reached on a worker.
 *
 * Seeds: every function no edge reaches, and then — until none is left — every function the walk did not reach that
 * `seedable` admits and no function the walk reached calls or references, each MAIN under the valuation that knows
 * nothing; a quiet root turns the main thread QUIET on entry.
 * A call carries what `EdgeConditions.carried` lets through; a callback `Ref` carries the context `callbackContext`
 * gives it, unless `inertRef` says the value is never run from there, and hands the callee no known parameter.
 */
@:nullSafety(Strict)
final class ThreadStates {

	/** The origin of the main thread among a function's threads (`origins`); a worker's is the callback starting it. */
	public static inline final MAIN_ORIGIN: String = '<main>';

	/** Each function's contexts, the union over its states. */
	public final contexts: Map<String, Int> = [];

	/**
	 * The functions seeded MAIN because nothing the walk knows runs them: their thread is an assumption, not a finding,
	 * and a question that turns on a function running on the main thread ALONE treats theirs as unknown.
	 */
	public final assumed: Map<String, Bool> = [];

	private final _states: Map<String, ThreadState> = [];
	private final _byNode: Map<String, Array<ThreadState>> = [];
	private final _queue: Array<ThreadState> = [];
	private final _graph: CallGraph;
	private final _conditions: EdgeConditions;
	private final _callbackContext: (CallEdge, Int) -> Int;
	private final _quiet: Array<String>;

	/** Whether a value handed on is never run from where it is handed (`ThreadSafety.runsNothing`). */
	private final _inertRef: (CallEdge) -> Bool;

	public function new(
		graph: CallGraph, conditions: EdgeConditions, quiet: Array<String>, callbackContext: (CallEdge, Int) -> Int,
		inertRef: (CallEdge) -> Bool, seedable: (String) -> Bool
	) {
		_graph = graph;
		_conditions = conditions;
		_callbackContext = callbackContext;
		_quiet = quiet;
		_inertRef = inertRef;
		solve(inertRef, seedable);
	}

	/**
	 * Whether the edge `e` may run its target from its function: a call, or a value handed on to run unless `inertRef`
	 * says nothing runs it from there — what a walk over the code a function runs follows (`LockReleasers`, `LockTaint`,
	 * the helper inference of `LockSites`).
	 */
	public static inline function runsWith(e: CallEdge, inertRef: (CallEdge) -> Bool): Bool {
		return e.kind.isInvocation() || e.kind == Ref && !inertRef(e);
	}

	/** `runsWith` under this solve's `inertRef`. */
	public inline function runsFrom(e: CallEdge): Bool {
		return runsWith(e, _inertRef);
	}

	/** Every state of `id` the walk reached: each valuation of its tracked parameters, with the contexts it runs it on. */
	public function statesOf(id: String): Array<{ valuation: String, ctx: Int }> {
		return [for (state in _byNode[id] ?? []) { valuation: state.valuation, ctx: state.ctx }];
	}

	/**
	 * The contexts `edge` runs its target in, over every state of its function: a call's, narrowed by the conditions
	 * around it, or a callback's as `callbackContext` makes it.
	 */
	public function edgeContext(edge: CallEdge): Int {
		var ctx: Int = 0;
		for (state in _byNode[edge.from] ?? []) {
			final live: Int = _conditions.carried(edge, state.valuation, state.ctx);
			if (live != 0) ctx |= edge.kind == Ref ? _callbackContext(edge, live) : live;
		}
		return ctx;
	}

	/**
	 * `[root, ..., from]` — how the main thread reached a state of `edge.from` that runs `edge` there, every hop, ending
	 * where a parent repeats; `[edge.from]` when no state does.
	 */
	public function mainPath(edge: CallEdge): Array<String> {
		final start: Null<ThreadState> = (
			_byNode[edge.from] ?? []
		).find(s -> _conditions.carried(edge, s.valuation, s.ctx) & ThreadSafety.CTX_MAIN != 0);
		final parts: Array<String> = [edge.from];
		if (start == null) return parts;
		final visited: Array<ThreadState> = [start];
		var cursor: ThreadState = start;
		while (true) {
			final parent: Null<ThreadState> = cursor.parent;
			if (parent == null || visited.contains(parent)) break;
			parts.unshift(parent.id);
			visited.push(parent);
			cursor = parent;
		}
		return parts;
	}

	/** The fixed point: every state each seed reaches through the calls and callbacks that run from it. */
	private function solve(inertRef: (CallEdge) -> Bool, seedable: (String) -> Bool): Void {
		for (id => node in _graph.nodes) if (!node.isExternal && _graph.inEdges(id).length == 0 && seedable(id)) seed(id);
		var qi: Int = 0;
		while (true) {
			while (qi < _queue.length) {
				final state: ThreadState = _queue[qi++];
				for (edge in _graph.outEdges(state.id)) if (edge.kind != Contains && !(edge.kind == Ref && inertRef(edge))) {
					final live: Int = _conditions.carried(edge, state.valuation, state.ctx);
					if (live == 0) continue;
					if (edge.kind == Ref)
						arrive(edge.to, _conditions.unknown(edge.to), _callbackContext(edge, live), state)
					else
						arrive(edge.to, _conditions.bind(edge, state.valuation), live, state);
				}
			}
			// a function nothing reached is ASSUMED main — seeded INTO the worklist so the assumption reaches its callees —
			// unless a function the walk reached calls or references it: the walk then knew that call, and found it runs nowhere
			var seeded: Bool = false;
			for (id => node in _graph.nodes) if (!(node.isExternal || contexts.exists(id)) && seedable(id) && !walkedCaller(id)) {
				seed(id);
				seeded = true;
			}
			if (!seeded) break;
		}
	}

	/** `id` ASSUMED to run on the main thread under the valuation that knows nothing (`assumed`). */
	private function seed(id: String): Void {
		assumed[id] = true;
		arrive(id, _conditions.unknown(id), ThreadSafety.CTX_MAIN, null);
	}

	/** Whether a function the walk reached calls or references `id` — lexical containment aside, which runs nothing. */
	private function walkedCaller(id: String): Bool {
		return _graph.inEdges(id).exists(e -> e.kind != Contains && contexts.exists(e.from));
	}

	/** `id` entered under `valuation` on `ctx` from `parent`: a new state, or more context for a known one, queued either way. */
	private function arrive(id: String, valuation: String, ctx: Int, parent: Null<ThreadState>): Void {
		final entered: Int = enter(_quiet, id, ctx);
		final key: String = '$id|$valuation';
		final known: Null<ThreadState> = _states[key];
		if (known == null) {
			final state: ThreadState = {
				id: id,
				valuation: valuation,
				ctx: entered,
				parent: entered & ThreadSafety.CTX_MAIN != 0 ? parent : null
			};
			_states[key] = state;
			final list: Array<ThreadState> = _byNode[id] ?? [];
			list.push(state);
			_byNode[id] = list;
			contexts[id] = (contexts[id] ?? 0) | entered;
			_queue.push(state);
			return;
		}
		final merged: Int = known.ctx | entered;
		if (merged == known.ctx) return;
		if (known.ctx & ThreadSafety.CTX_MAIN == 0 && merged & ThreadSafety.CTX_MAIN != 0) known.parent = parent;
		known.ctx = merged;
		contexts[id] = (contexts[id] ?? 0) | merged;
		_queue.push(known);
	}

	/**
	 * The threads each function runs on, by origin: `MAIN_ORIGIN` for the main thread, loud or quiet, and for a worker
	 * the callback a `spawns` call starts it with (`callbackContext` making it background whatever registers it) — each
	 * such callback one thread, whatever spawns it. A worker origin flows along every edge carrying a background context, per
	 * state — under the valuation the worker hands down (`EdgeConditions.carried`), so a call a condition rules out there
	 * carries none — but a value handed to a `spawns` call, which starts an origin of its own, or one `inertRef` says is
	 * never run from there; a function no thread runs has none.
	 */
	public function origins(inertRef: (CallEdge) -> Bool): (String) -> Array<String> {
		final found: Map<String, Array<String>> = [];
		for (id => ctx in contexts) if (ctx & (ThreadSafety.CTX_MAIN | ThreadSafety.CTX_QUIET) != 0) found[id] = [MAIN_ORIGIN];
		final spawned: (CallEdge) -> Bool = e -> e.kind == Ref && _callbackContext(e, ThreadSafety.CTX_MAIN) == ThreadSafety.CTX_BG;
		final onWorker: (CallEdge) -> Bool = e ->
			e.kind != Contains && !(e.kind == Ref && inertRef(e)) && edgeContext(e) & ThreadSafety.CTX_BG != 0;
		for (start in _graph.edges) if (spawned(start) && onWorker(start)) {
			// per state: a call a condition rules out under the valuation the worker hands down carries no origin
			final seen: Map<String, Bool> = [];
			final queue: Array<{ id: String, valuation: String }> = [{ id: start.to, valuation: _conditions.unknown(start.to) }];
			var qi: Int = 0;
			while (qi < queue.length) {
				final at: { id: String, valuation: String } = queue[qi++];
				if (seen.exists('${at.id}|${at.valuation}')) continue;
				seen['${at.id}|${at.valuation}'] = true;
				final known: Array<String> = found[at.id] ?? [];
				if (!known.contains(start.to)) known.push(start.to);
				found[at.id] = known;
				for (e in _graph.outEdges(at.id)) if (!spawned(e) && onWorker(e)) {
					final next: Null<{ id: String, valuation: String }> = workerStep(e, at.valuation);
					if (next != null) queue.push(next);
				}
			}
		}
		return id -> found[id] ?? [];
	}

	/**
	 * The state a worker running a function under `valuation` enters through its edge `e`: the call's target under the
	 * values it hands down, a value handed on with nothing known; null when a condition rules `e` out there, or the value
	 * runs on no worker from there.
	 */
	private function workerStep(e: CallEdge, valuation: String): Null<{ id: String, valuation: String }> {
		final live: Int = _conditions.carried(e, valuation, ThreadSafety.CTX_BG);
		final ctx: Int = e.kind == Ref ? _callbackContext(e, live) : live;
		if (live == 0 || ctx & ThreadSafety.CTX_BG == 0) return null;
		return { id: e.to, valuation: e.kind == Ref ? _conditions.unknown(e.to) : _conditions.bind(e, valuation) };
	}

	/** A `mainPath` as text, its last `cap` hops after `...` when it is longer. */
	public static function chainText(path: Array<String>, cap: Int): String {
		return (path.length > cap + 1 ? ['...'].concat(path.slice(-(cap + 1))) : path).join(' -> ');
	}

	/** The context `ctx` becomes on entering `id`: the main thread goes quiet in a `quiet` root. */
	private static function enter(quiet: Array<String>, id: String, ctx: Int): Int {
		return quiet.contains(id) && ctx & ThreadSafety.CTX_MAIN != 0 ? (ctx & ~ThreadSafety.CTX_MAIN) | ThreadSafety.CTX_QUIET : ctx;
	}

}
