package anyparse.check;

import anyparse.check.LockSites.BlindCall;
import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockSites.LockPair;
import anyparse.query.CallGraph;
import haxe.Exception;

using Lambda;

/**
 * One `apqlint.json` chain's `thread-safety` lists: the three name lists resolved to graph ids, the lock pairs as
 * written (a malformed one is reported) and as resolved.
 */
typedef ChainLists = {

	/** The repetitions bounded few and cheap enough to run as once (`BoundedRepeats`), and the budget they are judged by. */
	final bounded: Array<anyparse.check.BoundedRepeats.BoundedRepeat>;

	final repeatBudgetMs: Null<Float>;

	/** Whether the chain names any `sinks` — a chain that names none is read for the graph and reports nothing. */
	final reports: Bool;

	final sinkIds: Array<String>;

	/** The sinks whose one call is short (`shortSinks`): long only where it repeats (`CallRepetition`). */
	final shortSinkIds: Array<String>;

	/** The bare `shortSinks` names: a call the graph resolves to nothing, by the name it is written with, that is brief once. */
	final shortNames: Array<String>;

	/** The call targets that run a function value handed to them once per element (`iterates`). */
	final iterateIds: Array<String>;

	/** The member names whose every call runs a function value handed to it once per element, by the name the call is written with. */
	final iterateNames: Array<String>;

	/**
	 * The call targets that keep a function value handed to them to run later, once per event however often it was
	 * registered (`registers`): a loop around the registration repeats nothing.
	 */
	final registerIds: Array<String>;

	/** The member names whose every call registers a function value so (`registerIds`), by the name the call is written with. */
	final registerNames: Array<String>;

	/** The `lockPairs` take members that take their lock shared (`sharedLocks`): such takes never wait for each other. */
	final sharedIds: Array<String>;

	/** The calls that never throw (`nonThrowing`): a `catch` around nothing else is no path (`DeadCatches`). */
	final nonThrowingIds: Array<String>;

	/** The bare `nonThrowing` names, for a call the graph resolves to nothing. */
	final nonThrowingNames: Array<String>;
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
 * One state of the walk toward a blocking call: its key, function, valuation and context, whether a call on the way
 * repeats, and the hold being judged as the state's function sees it (`LockDominance.carry`), when it still does.
 */
private typedef WalkState = {
	final key: String;
	final id: String;
	final valuation: String;
	final ctx: Int;
	final repeated: Bool;
	final under: Null<String>;

	/** The classes the state's function runs on an instance of (`AllocationSets`), when the way to it says. */
	final self: Null<String>;
}

/**
 * How a call held under a lock blocks: the functions it runs to the blocking call, that call, the lock it waits for, and
 * the calls taken on the way — the held call first, `end` last.
 */
typedef BlockingTrail = {
	final path: Array<String>;
	final end: CallEdge;
	final via: Null<String>;
	final edges: Array<CallEdge>;
}

/**
 * What a taint answering the LONG question needs beyond the plain one: the locks whose take blocks at all (the plain
 * solve's long locks — a take of one this taint's own `long` leaves out is
 * a short wait), where a call repeats, and whether a take counts at all.
 */
typedef TaintCost = {
	final blocking: Array<String>;
	final repetition: CallRepetition;

	/** Whether a take of a lock may count at all: never when the question is the holder's own work, a take being a wait on another. */
	final takes: Bool;

	/**
	 * Which takes of a long lock wait briefly after all: the lock dominated by one held there (`LockDominance`), must-held
	 * under the valuation, or taken by the hold being judged.
	 */
	final dominance: LockDominance;

	/** Set for the taint asking about the NORMAL paths: the calls only an error path runs (`ErrorPaths`) lead nowhere. */
	final errors: Null<ErrorPaths>;
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

	/** The takes that never wait (`QuietLocks`). */
	public final quiet: QuietLocks;

	/** The receivers whose classes the code says (`AllocationSets`): a dispatch none of them resolves to runs nothing. */
	private final _allocations: Null<AllocationSets>;

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

	/**
	 * Null for the plain taint, where every blocking call counts; set for the taint asking which calls block LONG, where
	 * `long` names the long locks and a short call counts only where it repeats (`costsLong`).
	 */
	private final _cost: Null<TaintCost>;

	public function new(
		graph: CallGraph, sinkIds: Array<String>, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>,
		conditions: EdgeConditions, threads: ThreadStates, ?cost: TaintCost, ?allocations: AllocationSets
	) {
		_cost = cost;
		_allocations = allocations;
		quiet = new QuietLocks(sites, listsOf);
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

	/** A taint over the same graph, lists, sites, conditions and threads as this one, judging locks long by `long`, with nothing kept. */
	public function withLong(long: Array<String>): LockTaint {
		return new LockTaint(_graph, _sinkIds, listsOf, _sites, long, _conditions, _threads, _cost, _allocations);
	}

	/**
	 * The taint over the same graph, lists, sites, conditions and threads asking which calls block LONG, judging locks long
	 * by `long`, a take of a lock this one's `long` names and `long` leaves out a short wait, and repetition by `repetition`.
	 */
	public function costed(long: Array<String>, repetition: CallRepetition, dominance: LockDominance, ?errors: ErrorPaths): LockTaint {
		return new LockTaint(_graph, _sinkIds, listsOf, _sites, long, _conditions, _threads, {
			blocking: _long,
			repetition: repetition,
			takes: true,
			dominance: dominance,
			errors: errors
		}, _allocations);
	}

	/**
	 * The taint asking which calls are the holder's OWN long work — what a hold blocks by when no other thread is there
	 * to make it wait: the long and repeating calls of this costed taint, every take of a lock left out. Null on the
	 * plain taint, which knows nothing of cost.
	 */
	public function ownWork(): Null<LockTaint> {
		final cost: Null<TaintCost> = _cost;
		return cost == null
			? null
			: new LockTaint(_graph, _sinkIds, listsOf, _sites, [], _conditions, _threads, {
				blocking: cost.blocking,
				repetition: cost.repetition,
				takes: false,
				dominance: cost.dominance,
				errors: cost.errors
			}, _allocations);
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
	 * Whether the hold `a` spans an unresolved call that makes its lock long on its own (`LongLockExplain.blind`): any one
	 * for the plain taint; asking about cost, one that is not brief (`briefBlind`). An untraced hold always does.
	 */
	public function blindLong(a: LockAcquire): Bool {
		return LongLockExplain.blind(a) && (_cost == null || a.untraced || a.blindCalls.exists(c -> !briefBlind(a, c)));
	}

	/**
	 * Whether the unresolved call `c` the hold `a` spans waits briefly, asking about cost: one a bare `shortSinks` name
	 * names, run at most once under the hold (`CallRepetition.onceUnder`) — an unresolved `trace` — or, over the normal
	 * paths, one only a `catch` runs. Never on the plain taint.
	 */
	public function briefBlind(a: LockAcquire, c: BlindCall): Bool {
		final cost: Null<TaintCost> = _cost;
		if (cost == null) return false;
		final once: Bool = listsOf(a.edge.file).shortNames.contains(c.name) && cost.repetition.onceUnder(a.edge, c.span.from);
		return once || cost.errors?.catchAt(a.edge.file, c.span) != null;
	}

	/**
	 * Whether `edge` itself blocks under a hold of `held`: a sink call its site's chain names, one taking a lock only
	 * when the lock is long or unknown, and never a re-take of `held`.
	 */
	public function blocks(edge: CallEdge, held: Null<String>): Bool {
		if (!edge.kind.isInvocation() || !listsOf(edge.file).sinkIds.contains(edge.to)) return false;
		if (!takesLock(edge)) return true;
		final lock: Null<String> = _sites.lockOf(edge);
		if (quiet.never(edge)) return false;
		return lock == null || !(lock == held && _sites.selfTake(edge)) && blockingLocks().contains(lock);
	}

	/**
	 * Whether the blocking call `edge` (`blocks`, `retakesElsewhere`) waits long even once, under a hold of `held`: a take
	 * of a long lock or of one no member names, any other sink its site's chain does not list under `shortSinks`. The
	 * plain taint's every blocking call is.
	 */
	public function costsLong(edge: CallEdge, held: Null<String>, ?valuation: String): Bool {
		if (_cost == null) return true;
		if (retakesElsewhere(edge, held)) return held != null && _long.contains(held);
		if (!takesLock(edge)) return !listsOf(edge.file).shortSinkIds.contains(edge.to);
		final lock: Null<String> = _sites.lockOf(edge);
		return lock == null || _long.contains(lock) && !(_cost?.dominance.dominated(edge, valuation) == true);
	}

	/**
	 * The call path by which the call `edge` of the hold `a`, under a hold of `held`, blocks on some thread the hold runs
	 * on — `[edge.to]` for a call that blocks itself, `edge.to` and the functions after it toward the blocking call
	 * otherwise; null when it blocks on none: `edge` blocks, reaches a sink through no lock, or runs on another object a
	 * function that takes the held lock on its own (`retakesElsewhere`), each only in a state of the holder's function
	 * that runs both the take and `edge`.
	 */
	public function blockingPath(a: LockAcquire, edge: CallEdge, held: Null<String>): Null<Array<String>> {
		return blockingTrail(a, edge, held)?.path;
	}

	/**
	 * `blockingPath`, with the call at its end that blocks (`end`) and, when that call blocks by taking a lock, the lock
	 * (`via`: the lock object, the pair's take member for a lock no member names, or `held` for a take of it on another
	 * object). The one walk both answers come from.
	 */
	public function blockingTrail(a: LockAcquire, edge: CallEdge, held: Null<String>): Null<BlockingTrail> {
		if (onErrorPath(a.edge) || onErrorPath(edge)) return null;
		for (state in _threads.statesOf(a.edge.from)) for (bit in THREAD_BITS) if (
			state.ctx & bit != 0 && _conditions.carried(a.edge, state.valuation, bit) != 0
		) {
			final live: Int = _conditions.carried(edge, state.valuation, bit);
			if (live == 0) continue;
			final cost: Null<TaintCost> = _cost;
			// a call repeating while the lock is held runs every short call it reaches more than once
			final repeats: Bool = cost != null && cost.repetition.repeatedUnder(edge, a.edge);
			// the hold being judged, on the object it is taken on, while its window runs
			final under: Null<String> = cost?.dominance.holdOf(a);
			if (blocks(edge, held) || retakesElsewhere(edge, held)) {
				// a take the hold itself dominates, or a re-take of its own lock, waits for no long hold: each needs the lock held here
				if (counts(edge, held, repeats, state.valuation) && !briefUnder(under, edge)) return trailOf([edge.to], edge, held, [edge]);
				continue;
			}
			if (takesLock(edge)) continue;
			final classes: Null<String> = _allocations?.receiverClasses(edge, null);
			if (_allocations?.dispatches(edge, classes) == false) continue;
			final carried: Null<String> = cost?.dominance.carry(under, edge);
			final self: Null<String> = _allocations?.into(edge, classes);
			final key: Null<String> = reach(
				edge.to, _conditions.bind(edge, state.valuation), live, { held: held, repeated: repeats }, carried, self
			);
			if (key != null) return trailFrom(edge, key, held);
		}
		return null;
	}

	/** The calls of the hold `a`'s window that block under a hold of `held` (`blockingPath`), each with its path, in source order. */
	public function blockingCalls(a: LockAcquire, held: Null<String>): Array<{ edge: CallEdge, path: Array<String> }> {
		final blocking: Array<{ edge: CallEdge, path: Array<String> }> = [];
		for (e in a.window) if (e.span != null) {
			final path: Null<Array<String>> = blockingPath(a, e, held);
			if (path != null) blocking.push({ edge: e, path: path });
		}
		blocking.sort((x, y) -> (x.edge.span?.from ?? 0) - (y.edge.span?.from ?? 0));
		return blocking;
	}

	/** Whether `edge` calls, on an object other than its caller's, a function taking the long instance lock `held` on its own. */
	public function retakesElsewhere(edge: CallEdge, held: Null<String>): Bool {
		return held != null && blockingLocks().contains(held) && !_sites.isStaticLock(held) && edge.kind.isInvocation()
			&& selfTakers(held).contains(edge.to) && !_sites.selfCall(edge);
	}

	/** The locks whose take blocks at all: the plain taint's `long`, or the plain solve's for a taint asking about cost. */
	private inline function blockingLocks(): Array<String> {
		return _cost?.blocking ?? _long;
	}

	/** Whether a call that blocks counts toward this taint's question: every one for the plain taint, else a long or `repeats` one. */
	private inline function counts(edge: CallEdge, held: Null<String>, repeats: Bool, valuation: String): Bool {
		final cost: Null<TaintCost> = _cost;
		return cost == null || (cost.takes || !(takesLock(edge) || retakesElsewhere(edge, held)))
			&& (repeats || costsLong(edge, held, valuation));
	}

	/** Whether this taint asks about the normal paths and only an error path runs the call `edge` (`ErrorPaths`). */
	private inline function onErrorPath(edge: CallEdge): Bool {
		return _cost?.errors?.inCatch(edge) == true;
	}

	/** Whether this taint asks about cost and the call `edge` may run more than once per run of its function (`CallRepetition`). */
	private inline function repeatsAt(edge: CallEdge): Bool {
		return _cost?.repetition.repeated(edge) == true;
	}

	/**
	 * The key of the state `id` under `valuation` on `ctx` when some path of calls that run from it reaches a call that
	 * blocks under a hold of `held`; null when none does. A breadth-first walk over the states, each answer kept: a
	 * found path marks every state on it, a walk that found nothing every state it saw. A call taking a lock blocks by
	 * what the lock is (`blocks`), never through the lock primitive's own body, and a function its call site's chain
	 * names a sink is where a path ENDS: the call to it blocks by that name. Asking about cost, a state also carries
	 * whether a call on the way to it repeats (`repeated`, from the caller for the first): a short call (`costsLong`)
	 * counts only on a path that repeats; run once, it ends no path and leads nowhere, like any sink.
	 */
	private function reach(
		id: String, valuation: String, ctx: Int, flags: { held: Null<String>, repeated: Bool }, under: Null<String>, self: Null<String>
	): Null<String> {
		final held: Null<String> = flags.held;
		final repeated: Bool = flags.repeated;
		final root: String = stateKey(held, id, valuation, ctx, repeated, under) + '|${self ?? ''}';
		if (_reaching.exists(root)) return root;
		if (_clean.exists(root)) return null;
		final queue: Array<WalkState> = [
			{
				key: root,
				id: id,
				valuation: valuation,
				ctx: ctx,
				repeated: repeated,
				under: under,
				self: self
			}
		];
		final parents: Map<String, { key: String, edge: CallEdge }> = [];
		final seen: Map<String, Bool> = [root => true];
		var qi: Int = 0;
		while (qi < queue.length) {
			final state: WalkState = queue[qi++];
			for (edge in _graph.outEdges(state.id)) if (edge.kind.isInvocation()) {
				// the edge leaves `from`'s body, so its file's chain is the one that says whether `from` is a sink
				if (listsOf(edge.file).sinkIds.contains(edge.from) || onErrorPath(edge)) continue;
				final live: Int = _conditions.carried(edge, state.valuation, state.ctx);
				if (live == 0) continue;
				final repeats: Bool = state.repeated || repeatsAt(edge);
				if (blockingHere(edge, held)) {
					// a short call run once on this path waits too little to count, and a sink leads nowhere
					if (!counts(edge, held, repeats, state.valuation) || briefUnder(state.under, edge)) continue;
					final step: TaintStep = { edge: edge, next: null };
					_reaching[state.key] = step;
					markPath(state.key, parents);
					return root;
				}
				if (takesLock(edge)) continue;
				final nextState: Null<WalkState> = following(state, edge, live, { held: held, repeated: repeats });
				if (nextState == null) continue;
				final next: String = nextState.key;
				if (_clean.exists(next) || seen.exists(next)) continue;
				seen[next] = true;
				parents[next] = { key: state.key, edge: edge };
				if (_reaching.exists(next)) {
					markPath(next, parents);
					return root;
				}
				queue.push(nextState);
			}
		}
		for (key in seen.keys()) _clean[key] = true;
		return null;
	}

	/** Whether the call `edge` of a walk blocks itself under a hold of `held`: a sink call that blocks, or a re-take elsewhere. */
	private inline function blockingHere(edge: CallEdge, held: Null<String>): Bool {
		return _sinkIds.contains(edge.to) && blocks(edge, held) || retakesElsewhere(edge, held);
	}

	/**
	 * The state the call `edge` of `state` enters on `live`, under a hold of `flags.held` and repeating or not: its
	 * valuation bound, the judged hold carried into it (`LockDominance.carry`), and the classes it runs on
	 * (`AllocationSets.into`); null for a dispatch no class the receiver may be resolves to, which runs nothing here.
	 */
	private function following(
		state: WalkState, edge: CallEdge, live: Int, flags: { held: Null<String>, repeated: Bool }
	): Null<WalkState> {
		final classes: Null<String> = _allocations?.receiverClasses(edge, state.self);
		if (_allocations?.dispatches(edge, classes) == false) return null;
		final valuation: String = _conditions.bind(edge, state.valuation);
		final under: Null<String> = _cost?.dominance.carry(state.under, edge);
		final self: Null<String> = _allocations?.into(edge, classes);
		return {
			key: stateKey(flags.held, edge.to, valuation, live, flags.repeated, under) + '|${self ?? ''}',
			id: edge.to,
			valuation: valuation,
			ctx: live,
			repeated: flags.repeated,
			under: under,
			self: self
		};
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
	 * The call `first`'s target and the functions the kept steps from the state `key` it enters call, up to the blocking
	 * call's target: the steps one walk keeps form a tree toward the call it found, and a later walk only adds states no
	 * earlier one saw.
	 */
	private function trailFrom(first: CallEdge, key: String, held: Null<String>): BlockingTrail {
		final parts: Array<String> = [first.to];
		final edges: Array<CallEdge> = [first];
		var cursor: Null<String> = key;
		var end: Null<CallEdge> = null;
		while (cursor != null) {
			final step: Null<TaintStep> = _reaching[cursor];
			if (step == null) break;
			parts.push(step.edge.to);
			edges.push(step.edge);
			end = step.edge;
			cursor = step.next;
		}
		final last: Null<CallEdge> = end;
		if (last == null) throw new Exception('thread-safety: a reaching state "$key" keeps no step toward its blocking call');
		return trailOf(parts, last, held, edges);
	}

	/**
	 * The trail `path` ending in the blocking call `end`, under a hold of `held`, with the lock `end` waits for and the
	 * calls `edges` taken on the way (`blockingTrail`).
	 */
	private function trailOf(path: Array<String>, end: CallEdge, held: Null<String>, edges: Array<CallEdge>): BlockingTrail {
		final via: Null<String> = if (retakesElsewhere(end, held))
			held
		else if (takesLock(end))
			_sites.lockOf(end) ?? end.to
		else
			null;
		return {
			path: path,
			end: end,
			via: via,
			edges: edges
		};
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
	public function takesLock(edge: CallEdge): Bool {
		final lists: ChainLists = listsOf(edge.file);
		return lists.sinkIds.contains(edge.to) && lists.pairs.exists(p -> p.lockId == edge.to);
	}

	private static inline function stateKey(
		held: Null<String>, id: String, valuation: String, ctx: Int, repeated: Bool, under: Null<String>
	): String {
		return '${held ?? ''}|$id|$valuation|$ctx${repeated ? '|repeated' : ''}|${under ?? ''}';
	}

	/**
	 * Whether the take `edge` waits for no long hold while the hold `under` (`LockDominance.holdOf`) is held: asking about
	 * cost, a re-take of that lock on its object by a `reentrantLocks` take, or a take of a lock it dominates there.
	 */
	private inline function briefUnder(under: Null<String>, edge: CallEdge): Bool {
		return under != null && takesLock(edge)
			&& _cost?.dominance.briefUnder(under, edge, listsOf(edge.file).reentrantIds.contains(edge.to)) == true;
	}

	/**
	 * Whether the call at the end of `trail`, which the call of the hold `a`'s window at its head leads to, runs more than
	 * once under the hold: that call repeats under the take, or a call on the way repeats (`CallRepetition`). Asked of a
	 * taint asking about cost: the plain one knows no repetition.
	 */
	public function repeatsAlong(a: LockAcquire, trail: BlockingTrail): Bool {
		final cost: Null<TaintCost> = _cost;
		if (cost == null) throw new Exception('thread-safety: the plain taint knows no repetition');
		final repetition: CallRepetition = cost.repetition;
		return trail.edges.length > 0 && repetition.repeatedUnder(trail.edges[0], a.edge)
			|| trail.edges.slice(1).exists(e -> repetition.repeated(e));
	}

}
