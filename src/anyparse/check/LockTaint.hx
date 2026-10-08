package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockSites.LockPair;
import anyparse.query.CallGraph;

using Lambda;

/**
 * One `apqlint.json` chain's `thread-safety` lists: the three name lists resolved to graph ids, the lock pairs as
 * written (a malformed one is reported) and as resolved.
 */
typedef ChainLists = {

	/** Whether the chain names any `sinks` — a chain that names none is read for the graph and reports nothing. */
	final reports: Bool;

	final sinkIds: Array<String>;
	final spawnIds: Array<String>;
	final marshalIds: Array<String>;
	final quietIds: Array<String>;

	/** The `lockPairs` take members whose lock the thread holding it may take again without waiting. */
	final reentrantIds: Array<String>;

	/** The calls known to raise an exception with no body to say so (`ThrowReach`). */
	final throwerIds: Array<String>;

	/** The call targets that never run a function value handed to them (`removeEventListener`). */
	final neverInvokeIds: Array<String>;

	/** The member names whose every call never runs a function value handed to it, by the name the call is written with. */
	final neverInvokeNames: Array<String>;

	/** The reads or calls answering whether the running thread is the main one (`EdgeConditions`). */
	final mainCheckIds: Array<String>;

	/** Whether every invocation of the chain's code is a call the run's files write (`closedWorld`). */
	final closedWorld: Bool;
	final lockPairs: Array<String>;
	final pairs: Array<LockPair>;
}

/** One step of a path toward a blocking call: the call taken, and the state it enters — none when the call itself blocks. */
private typedef TaintStep = {
	final edge: CallEdge;
	final next: Null<String>;
}

/**
 * Which calls block, and whether a call held under a lock reaches one — for a hold of each re-entrant lock the holder
 * may take again freely, the plain question under `null` — answered over the thread STATES of `ThreadStates` (a
 * function, the valuation of its tracked parameters, one context bit): a call a condition rules out on that path, or
 * on that thread (`EdgeConditions.carried`), reaches nothing. The answers are kept and dropped by `clear` whenever the
 * long locks grow.
 *
 * A re-take is free only on the SAME object: every take of a static lock, and a take of an instance lock on the object
 * the holder runs on (`LockSites.selfTake`) — directly, or in a function reached by calls on that object alone. A call
 * on any other receiver into a function that takes the lock on its own object waits for another object's lock.
 */
@:nullSafety(Strict)
final class LockTaint {

	/** The context bits a state is split into: a call may block on one thread and not on another. */
	private static final THREAD_BITS: Array<Int> = [ThreadSafety.CTX_MAIN, ThreadSafety.CTX_BG, ThreadSafety.CTX_QUIET];

	public final listsOf: (String) -> ChainLists;

	/** `<held>|<function>|<valuation>|<bit>` -> the step toward a blocking call from that state. */
	private final _reaching: Map<String, TaintStep> = [];

	/** The state keys of `_reaching`'s form known to reach no blocking call. */
	private final _clean: Map<String, Bool> = [];

	/** Per held instance lock: the functions that take it on the object they run on, directly or by calls on that object. */
	private final _selfTakers: Map<String, Array<String>> = [];

	private final _graph: CallGraph;
	private final _sinkIds: Array<String>;
	private final _sites: LockSites;
	private final _long: Array<String>;
	private final _conditions: EdgeConditions;
	private final _threads: ThreadStates;

	public function new(
		graph: CallGraph, sinkIds: Array<String>, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>,
		conditions: EdgeConditions, threads: ThreadStates
	) {
		_graph = graph;
		_sinkIds = sinkIds;
		this.listsOf = listsOf;
		_sites = sites;
		_long = long;
		_conditions = conditions;
		_threads = threads;
	}

	public inline function clear(): Void {
		_reaching.clear();
		_clean.clear();
	}

	/**
	 * The lock `a` takes when its kind is `reentrantLocks`-listed, a member names it and the take provably works the
	 * holder's own object (`LockSites.selfTake`); null otherwise.
	 */
	public function reentrantHeld(a: LockAcquire): Null<String> {
		final lock: Null<String> = a.lock;
		return lock != null && listsOf(a.edge.file).reentrantIds.contains(a.pair.lockId) && _sites.selfTake(a.edge) ? lock : null;
	}

	/**
	 * Whether `edge` itself blocks under a hold of `held`: a sink call its site's chain names, one taking a lock only
	 * when the lock is long or unknown, and never a re-take of `held`.
	 */
	public function blocks(edge: CallEdge, held: Null<String>): Bool {
		if (!edge.kind.isInvocation() || !listsOf(edge.file).sinkIds.contains(edge.to)) return false;
		if (!takesLock(edge)) return true;
		final lock: Null<String> = _sites.lockOf(edge);
		return lock == null || !(lock == held && _sites.selfTake(edge)) && _long.contains(lock);
	}

	/**
	 * The call path by which the call `edge` of the hold `a`, under a hold of `held`, blocks on some thread the hold runs
	 * on — `[edge.to]` for a call that blocks itself, `edge.to` and the functions after it toward the blocking call
	 * otherwise; null when it blocks on none: `edge` blocks, reaches a sink through no lock, or runs on another object a
	 * function that takes the held lock on its own (`retakesElsewhere`), each only in a state of the holder's function
	 * that runs both the take and `edge`.
	 */
	public function blockingPath(a: LockAcquire, edge: CallEdge, held: Null<String>): Null<Array<String>> {
		for (state in _threads.statesOf(a.edge.from)) for (bit in THREAD_BITS) if (
			state.ctx & bit != 0 && _conditions.carried(a.edge, state.valuation, bit) != 0
		) {
			final live: Int = _conditions.carried(edge, state.valuation, bit);
			if (live == 0) continue;
			if (blocks(edge, held) || retakesElsewhere(edge, held)) return [edge.to];
			if (takesLock(edge)) continue;
			final key: Null<String> = reach(edge.to, _conditions.bind(edge, state.valuation), live, held);
			if (key != null) return pathFrom(edge.to, key);
		}
		return null;
	}

	/** Whether `edge` calls, on an object other than its caller's, a function taking the long instance lock `held` on its own. */
	public function retakesElsewhere(edge: CallEdge, held: Null<String>): Bool {
		return held != null && _long.contains(held) && !_sites.isStaticLock(held) && edge.kind.isInvocation()
			&& selfTakers(held).contains(edge.to) && !_sites.selfCall(edge);
	}

	/**
	 * The key of the state `id` under `valuation` on `ctx` when some path of calls that run from it reaches a call that
	 * blocks under a hold of `held`; null when none does. A breadth-first walk over the states, each answer kept: a
	 * found path marks every state on it, a walk that found nothing every state it saw. A call taking a lock blocks by
	 * what the lock is (`blocks`), never through the lock primitive's own body, and a function its call site's chain
	 * names a sink is where a path ENDS: the call to it blocks by that name.
	 */
	private function reach(id: String, valuation: String, ctx: Int, held: Null<String>): Null<String> {
		final root: String = stateKey(held, id, valuation, ctx);
		if (_reaching.exists(root)) return root;
		if (_clean.exists(root)) return null;
		final queue: Array<{
			key: String,
			id: String,
			valuation: String,
			ctx: Int
		}> = [
			{
				key: root,
				id: id,
				valuation: valuation,
				ctx: ctx
			}
		];
		final parents: Map<String, { key: String, edge: CallEdge }> = [];
		final seen: Map<String, Bool> = [root => true];
		var qi: Int = 0;
		while (qi < queue.length) {
			final state: {
				key: String,
				id: String,
				valuation: String,
				ctx: Int
			} = queue[qi++];
			for (edge in _graph.outEdges(state.id)) if (edge.kind.isInvocation()) {
				// the edge leaves `from`'s body, so its file's chain is the one that says whether `from` is a sink
				if (listsOf(edge.file).sinkIds.contains(edge.from)) continue;
				final live: Int = _conditions.carried(edge, state.valuation, state.ctx);
				if (live == 0) continue;
				if (_sinkIds.contains(edge.to) && blocks(edge, held) || retakesElsewhere(edge, held)) {
					final step: TaintStep = { edge: edge, next: null };
					_reaching[state.key] = step;
					markPath(state.key, parents);
					return root;
				}
				if (takesLock(edge)) continue;
				final nextValuation: String = _conditions.bind(edge, state.valuation);
				final next: String = stateKey(held, edge.to, nextValuation, live);
				if (_clean.exists(next) || seen.exists(next)) continue;
				seen[next] = true;
				parents[next] = { key: state.key, edge: edge };
				if (_reaching.exists(next)) {
					markPath(next, parents);
					return root;
				}
				queue.push({
					key: next,
					id: edge.to,
					valuation: nextValuation,
					ctx: live
				});
			}
		}
		for (key in seen.keys()) _clean[key] = true;
		return null;
	}

	/** Marks every state on the walk's way to `found` (a state that reaches a blocking call) as reaching one too. */
	private function markPath(found: String, parents: Map<String, { key: String, edge: CallEdge }>): Void {
		var cursor: String = found;
		while (true) {
			final parent: Null<{ key: String, edge: CallEdge }> = parents[cursor];
			if (parent == null) return;
			final step: TaintStep = { edge: parent.edge, next: cursor };
			_reaching[parent.key] = step;
			cursor = parent.key;
		}
	}

	/**
	 * `id` and the functions the kept steps from the state `key` call, up to the blocking call's target: the steps one walk
	 * keeps form a tree toward the call it found, and a later walk only adds states no earlier one saw.
	 */
	private function pathFrom(id: String, key: String): Array<String> {
		final parts: Array<String> = [id];
		var cursor: Null<String> = key;
		while (cursor != null) {
			final step: Null<TaintStep> = _reaching[cursor];
			if (step == null) break;
			parts.push(step.edge.to);
			cursor = step.next;
		}
		return parts;
	}


	/**
	 * The functions that take the instance lock `held` on the object they run on: a function whose own take of it is
	 * `LockSites.selfTake`, and every caller reaching one by calls on its own object (`LockSites.selfCall`).
	 */
	private function selfTakers(held: String): Array<String> {
		final known: Null<Array<String>> = _selfTakers[held];
		if (known != null) return known;
		final takers: Array<String> = [];
		_selfTakers[held] = takers;
		for (edge in _graph.edges) if (
			takesLock(edge) && !takers.contains(edge.from) && _sites.lockOf(edge) == held && _sites.selfTake(edge)
		)
			takers.push(edge.from);
		var qi: Int = 0;
		while (qi < takers.length) {
			final id: String = takers[qi++];
			for (edge in _graph.inEdges(id)) if (edge.kind.isInvocation() && !takers.contains(edge.from) && _sites.selfCall(edge))
				takers.push(edge.from);
		}
		return takers;
	}

	/** Whether `edge` is a call to a sink `lockPairs` names a lock of: one whose cost is the wait for that lock. */
	private function takesLock(edge: CallEdge): Bool {
		final lists: ChainLists = listsOf(edge.file);
		return lists.sinkIds.contains(edge.to) && lists.pairs.exists(p -> p.lockId == edge.to);
	}

	private static inline function stateKey(held: Null<String>, id: String, valuation: String, ctx: Int): String {
		return '${held ?? ''}|$id|$valuation|$ctx';
	}

}
