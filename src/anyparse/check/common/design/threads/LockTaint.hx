package anyparse.check.common.design.threads;

import anyparse.check.common.design.ThreadSafety;
import anyparse.check.common.design.threads.CallRepetition.BoundedWay;
import anyparse.check.common.design.threads.LockSites.BlindCall;
import anyparse.check.common.design.threads.LockSites.LockAcquire;
import anyparse.check.common.design.threads.LockSites.LockPair;
import anyparse.query.CallGraph;
import haxe.Exception;

/**
 * One `apqlint.json` chain's `thread-safety` lists: the three name lists resolved to graph ids, the lock pairs as
 * written (a malformed one is reported) and as resolved.
 */
typedef ChainLists = {

	/** The repetitions bounded few and cheap enough to run as once (`BoundedRepeats`), and the budget they are judged by. */
	final bounded: Array<anyparse.check.common.design.threads.BoundedRepeats.BoundedRepeat>;

	final repeatBudgetMs: Null<Float>;

	/**
	 * Whether the chain writes any option for the rule — the builtin sinks apply wherever
	 * it runs; a chain that writes none is read for the graph and reports nothing.
	 */
	final reports: Bool;

	/** The blocking calls: the `sinks` entries, and the builtin sinks and project natives no `nonBlocking` entry waives. */
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

	/**
	 * The call targets a `Type.member` entry of `registers` names: the project's word on that member, a project one
	 * included, where a bare name speaks for the runtime's calls only (`CallRepetition.registered`).
	 */
	final registerMemberIds: Array<String>;

	/**
	 * The call targets a `Type.member` entry of `runsOnce` names running a function value handed to them at most once
	 * per call, now or later: the one positive answer that a value handed to a call does not repeat (`CallRepetition`).
	 */
	final runsOnceIds: Array<String>;

	/**
	 * The member names whose every call runs a function value handed to it
	 * at most once so (`runsOnceIds`), by the name the call is written with.
	 */
	final runsOnceNames: Array<String>;

	/** The `lockPairs` take members that take their lock shared (`sharedLocks`): such takes never wait for each other. */
	final sharedIds: Array<String>;

	/** The calls that never throw (`nonThrowing`): a `catch` around nothing else is no path (`DeadCatches`). */
	final nonThrowingIds: Array<String>;

	/** The bare `nonThrowing` names, for a call the graph resolves to nothing. */
	final nonThrowingNames: Array<String>;
	final spawnIds: Array<String>;

	/**
	 * Each call target a `spawns` object entry names -> the positions of its arguments whose function value it runs on
	 * the main thread later instead (`ThreadStates.runsOnMain`).
	 */
	final mainArguments: Map<String, Array<Int>>;
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

	/** The repetitions `boundedRepeats` binds on the way to the state, counted as once while their product stays in budget. */
	final way: BoundedWay;
	final under: Null<String>;

	/** The classes the state's function runs on an instance of (`AllocationSets`), when the way to it says. */
	final self: Null<String>;
}

/** What a walk state carries down to the next one: the lock held, whether a call on the way repeats, and the bounded way. */
private typedef WalkFlags = {
	final held: Null<String>;
	final repeated: Bool;
	final way: BoundedWay;
}

/** What one call does from a walk state (`LockTaint.stepOf`): nothing there, block — repeating or not — or enter a state. */
private enum WalkStep {
	Skip;
	Blocks(repeated: Bool);
	Enter(state: WalkState);
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
 * One call that blocks which a call held under a lock reaches, over EVERY way to it (`LockTaint.blockingEnds`): the
 * shortest way, whether it runs more than once under the hold on some way (`repeated`) or may (`mayRepeat`, a function
 * on some way re-entered through a cycle of calls), and the functions every way to it passes (`passes`: the held call's
 * target and the blocking call's among them).
 */
typedef BlockingEnd = {
	final trail: BlockingTrail;
	final repeated: Bool;
	final mayRepeat: Bool;
	final passes: Array<String>;
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

	/** The most functions `onCycle` walks before it answers that calls may lead back. */
	private static inline final CYCLE_WALK: Int = 4096;

	/** The context bits a state is split into: a call may block on one thread and not on another. */
	private static final THREAD_BITS: Array<Int> = [ThreadSafety.CTX_MAIN, ThreadSafety.CTX_BG, ThreadSafety.CTX_QUIET];

	public final listsOf: (String) -> ChainLists;

	/** The takes that never wait (`QuietLocks`). */
	public final quiet: QuietLocks;

	/** `<held>|<function>|<valuation>|<bit>` -> the step toward a blocking call from that state. */
	private final _reaching: Map<String, TaintStep> = [];

	/** The state keys of `_reaching`'s form known to reach no blocking call. */
	private final _clean: Map<String, Bool> = [];

	/** Per held instance lock: the functions that take it on the object they run on, directly or by calls on that object. */
	private final _selfTakers: Map<String, Array<String>> = [];

	/** Each function -> whether calls from it may lead back to it (`onCycle`). */
	private final _cyclic: Map<String, Bool> = [];

	/** The receivers whose classes the code says (`AllocationSets`): a dispatch none of them resolves to runs nothing. */
	private final _allocations: Null<AllocationSets>;

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
	 * Whether `edge` itself blocks under a hold of `held`: a sink call its site's chain names — or a sink handed on as a
	 * value that runs from there (`ThreadStates.runsFrom`) — one taking a lock only when the lock is long or unknown, and
	 * never a re-take of `held`.
	 */
	public function blocks(edge: CallEdge, held: Null<String>): Bool {
		if (!_threads.runsFrom(edge) || !listsOf(edge.file).sinkIds.contains(edge.to)) return false;
		if (!takesLock(edge)) return true;
		final lock: Null<String> = _sites.lockOf(edge);
		return !quiet.never(edge) && (lock == null || !(lock == held && _sites.selfTake(edge)) && blockingLocks().contains(lock));
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
		return lock == null || _long.contains(lock) && _cost?.dominance.dominated(edge, valuation) != true;
	}

	/**
	 * How the call `edge` of the hold `a`, under a hold of `held`, blocks on some thread the hold runs on, each only in a
	 * state of the holder's function that runs both the take and `edge`: the first way found (`path`: `[edge.to]` for a
	 * call that blocks itself, `edge.to` and the functions after it toward the blocking call otherwise), the call at its
	 * end that blocks (`end`) and, when that call blocks by taking a lock, the lock (`via`: the lock object, the pair's take
	 * member for a lock no member names, or `held` for a take of it on another object); null when it blocks on none.
	 * `edge` blocks, reaches a sink through no lock, or runs on another object a function that takes the held lock on its
	 * own (`retakesElsewhere`). `blockingEnds` answers for every blocking call the call reaches.
	 */
	public function blockingTrail(a: LockAcquire, edge: CallEdge, held: Null<String>): Null<BlockingTrail> {
		for (root in rootsOf(a, edge, held)) switch root {
			case Blocks(_):
				return trailOf([edge.to], edge, held, [edge]);
			case Enter(state):
				final key: Null<String> = reach(state, held);
				if (key != null) return trailFrom(edge, key, held);
			case Skip:
		}
		return null;
	}

	/**
	 * EVERY call that blocks which the call `edge` of the hold `a` reaches under a hold of `held` — `blockingTrail` names
	 * the first — each once by its site and the lock it waits for (`BlockingEnd`): the shortest way to it, whether some
	 * way repeats it, and the functions every way passes. Empty when the call blocks on no way. A walk of its own over
	 * the same states, keeping no answer for another call: each state is entered once, so it ends with the states.
	 */
	public function blockingEnds(a: LockAcquire, edge: CallEdge, held: Null<String>): Array<BlockingEnd> {
		final ways: EndGraph = new EndGraph(edge);
		for (root in rootsOf(a, edge, held)) switch root {
			case Blocks(repeated):
				ways.blocked(-1, edge, repeated);
			case Enter(state):
				ways.enter(state, -1, edge);
			case Skip:
		}
		var qi: Int = 0;
		while (qi < ways.states.length) {
			final at: Int = qi++;
			final state: WalkState = ways.states[at];
			for (e in _graph.outEdges(state.id)) switch stepOf(state, e, held) {
				case Blocks(repeated):
					ways.blocked(at, e, repeated);
				case Enter(next):
					ways.enter(next, at, e);
				case Skip:
			}
		}
		return ways.ends(onCycle, (path, end, edges) -> trailOf(path, end, held, edges));
	}

	/** The calls of the hold `a`'s window that block under a hold of `held` (`blockingTrail`), each with its path, in source order. */
	public function blockingCalls(a: LockAcquire, held: Null<String>): Array<{ edge: CallEdge, path: Array<String> }> {
		final blocking: Array<{ edge: CallEdge, path: Array<String> }> = [];
		for (e in a.window) if (e.span != null) {
			final path: Null<Array<String>> = blockingTrail(a, e, held)?.path;
			if (path != null) blocking.push({ edge: e, path: path });
		}
		blocking.sort((x, y) -> (x.edge.span?.from ?? 0) - (y.edge.span?.from ?? 0));
		return blocking;
	}

	/** Whether `edge` calls, on an object other than its caller's, a function taking the long instance lock `held` on its own. */
	public function retakesElsewhere(edge: CallEdge, held: Null<String>): Bool {
		return held != null
			&& blockingLocks().contains(held)
			&& !_sites.isStaticLock(held)
			&& _threads.runsFrom(edge)
			&& selfTakers(held).contains(edge.to)
			&& !_sites.selfCall(edge);
	}

	/** Whether `edge` is a call to a sink `lockPairs` names a lock of: one whose cost is the wait for that lock. */
	public function takesLock(edge: CallEdge): Bool {
		final lists: ChainLists = listsOf(edge.file);
		return lists.sinkIds.contains(edge.to) && lists.pairs.exists(p -> p.lockId == edge.to);
	}

	/** The locks whose take blocks at all: the plain taint's `long`, or the plain solve's for a taint asking about cost. */
	private inline function blockingLocks(): Array<String> {
		return _cost?.blocking ?? _long;
	}

	/** Whether a call that blocks counts toward this taint's question: every one for the plain taint, else a long or `repeats` one. */
	private inline function counts(edge: CallEdge, held: Null<String>, repeats: Bool, valuation: String): Bool {
		final cost: Null<TaintCost> = _cost;
		return cost == null
			|| (cost.takes || !(takesLock(edge) || retakesElsewhere(edge, held)))
			&& (repeats || costsLong(edge, held, valuation));
	}

	/**
	 * Whether the call `edge` of a walk leads nowhere: a call out of a sink's own body — the edge leaves `from`'s body, so
	 * its file's chain is the one that says whether `from` is a sink — or, asking about the normal paths, one only an
	 * error path runs (`onErrorPath`), unless a call on the way to it repeats (`repeated`): every turn may fail, and the
	 * `catch` is then a path of the normal run.
	 */
	private inline function leadsNowhere(edge: CallEdge, repeated: Bool): Bool {
		return listsOf(edge.file).sinkIds.contains(edge.from) || !repeated && onErrorPath(edge);
	}

	/** Whether this taint asks about the normal paths and only an error path runs the call `edge` (`ErrorPaths`). */
	private inline function onErrorPath(edge: CallEdge): Bool {
		return _cost?.errors?.inCatch(edge) == true;
	}

	/** Whether this taint asks about cost and the call `edge` may run more than once per run of its function (`CallRepetition`). */
	private inline function repeatsAt(edge: CallEdge): Bool {
		return _cost?.repetition.repeated(edge) == true;
	}

	/** Whether the call `edge` of a walk blocks itself under a hold of `held`: a sink call that blocks, or a re-take elsewhere. */
	private inline function blockingHere(edge: CallEdge, held: Null<String>): Bool {
		return _sinkIds.contains(edge.to) && blocks(edge, held) || retakesElsewhere(edge, held);
	}

	/**
	 * Whether the take `edge` waits for no long hold while the hold `under` (`LockDominance.holdOf`) is held: asking about
	 * cost, a re-take of that lock on its object by a `reentrantLocks` take, or a take of a lock it dominates there.
	 */
	private inline function briefUnder(under: Null<String>, edge: CallEdge): Bool {
		return under != null
			&& takesLock(edge)
			&& _cost?.dominance.briefUnder(under, edge, listsOf(edge.file).reentrantIds.contains(edge.to)) == true;
	}

	/** `way` extended by the call `edge` asking about cost (`CallRepetition.along`); `way` itself for the plain taint. */
	private inline function wayAt(edge: CallEdge, way: BoundedWay): Null<BoundedWay> {
		final cost: Null<TaintCost> = _cost;
		return cost == null ? way : cost.repetition.along(edge, way);
	}

	/**
	 * The key of the state `start` when some path of calls that run from it (`stepOf`) — a value handed to a call that
	 * runs it there among them (`ThreadStates.runsHere`), repeating as that call repeats it — reaches a call that blocks
	 * under a hold of `held`; null when none does. A breadth-first walk over the states, each answer kept: a
	 * found path marks every state on it, a walk that found nothing every state it saw. A call taking a lock blocks by
	 * what the lock is (`blocks`), never through the lock primitive's own body, and a function its call site's chain
	 * names a sink is where a path ENDS: the call to it blocks by that name. Asking about cost, a state also carries
	 * whether a call on the way to it repeats (`repeated`, from the caller for the first): a short call (`costsLong`)
	 * counts only on a path that repeats; run once, it ends no path and leads nowhere, like any sink.
	 */
	private function reach(start: WalkState, held: Null<String>): Null<String> {
		final root: String = start.key;
		if (_reaching.exists(root)) return root;
		if (_clean.exists(root)) return null;
		final queue: Array<WalkState> = [start];
		final parents: Map<String, { key: String, edge: CallEdge }> = [];
		final seen: Map<String, Bool> = [root => true];
		var qi: Int = 0;
		while (qi < queue.length) {
			final state: WalkState = queue[qi++];
			for (edge in _graph.outEdges(state.id)) switch stepOf(state, edge, held) {
				case Blocks(_):
					final step: TaintStep = { edge: edge, next: null };
					_reaching[state.key] = step;
					markPath(state.key, parents);
					return root;
				case Enter(nextState):
					final next: String = nextState.key;
					if (_clean.exists(next) || seen.exists(next)) continue;
					seen[next] = true;
					parents[next] = { key: state.key, edge: edge };
					if (_reaching.exists(next)) {
						markPath(next, parents);
						return root;
					}
					queue.push(nextState);
				case Skip:
			}
		}
		for (key in seen.keys()) _clean[key] = true;
		return null;
	}

	/**
	 * What the call `edge` of the hold `a` does under a hold of `held`, in each state of the holder's function and on each
	 * thread that runs both the take and `edge` (none for a call no thread runs there, or only an error path runs): blocks
	 * itself, repeating or not, or enters the state its target runs in, carrying the repetitions around it, the judged
	 * hold and the classes it runs on.
	 */
	private function rootsOf(a: LockAcquire, edge: CallEdge, held: Null<String>): Array<WalkStep> {
		final roots: Array<WalkStep> = [];
		if (!_threads.runsHere(edge, listsOf(edge.file)) || onErrorPath(a.edge) || onErrorPath(edge)) return roots;
		for (state in _threads.statesOf(a.edge.from)) for (bit in THREAD_BITS) if (
			state.ctx & bit != 0 && _conditions.carried(a.edge, state.valuation, bit) != 0
		) {
			final live: Int = _conditions.carried(edge, state.valuation, bit);
			if (live == 0) continue;
			final cost: Null<TaintCost> = _cost;
			// the repetitions `boundedRepeats` binds around the call while the lock is held, multiplied on along the way
			final way: Null<BoundedWay> = cost == null
				? CallRepetition.UNBOUNDED
				: cost.repetition.alongUnder(edge, a.edge, CallRepetition.UNBOUNDED);
			// a call repeating while the lock is held runs every short call it reaches more than once
			final repeats: Bool = cost != null && (cost.repetition.repeatedUnder(edge, a.edge) || way == null);
			// the hold being judged, on the object it is taken on, while its window runs
			final under: Null<String> = cost?.dominance.holdOf(a);
			if (blocks(edge, held) || retakesElsewhere(edge, held)) {
				// a take the hold itself dominates, or a re-take of its own lock, waits for no long hold: each needs the lock held here
				if (counts(edge, held, repeats, state.valuation) && !briefUnder(under, edge)) roots.push(Blocks(repeats));
				continue;
			}
			if (takesLock(edge)) continue;
			final classes: Null<String> = _allocations?.receiverClasses(edge, null);
			if (_allocations?.dispatches(edge, classes) == false) continue;
			final flags: WalkFlags = { held: held, repeated: repeats, way: way ?? CallRepetition.UNBOUNDED };
			final valuation: String = _conditions.entered(edge, state.valuation);
			final carried: Null<String> = cost?.dominance.carry(under, edge);
			final self: Null<String> = _allocations?.into(edge, classes);
			roots.push(Enter({
				key: stateKey(held, edge.to, valuation, live, flags, carried) + '|${self ?? ''}',
				id: edge.to,
				valuation: valuation,
				ctx: live,
				repeated: repeats,
				way: flags.way,
				under: carried,
				self: self
			}));
		}
		return roots;
	}

	/**
	 * What the call `edge` of the walk state `state` does under a hold of `held`: nothing — it runs nowhere from here or
	 * leads nowhere (`leadsNowhere`), a condition rules it out, it blocks too briefly to count (a short call run once, a
	 * take the judged hold dominates), it takes a lock, or no class its receiver may be runs it — block, repeating or not,
	 * or enter the state its target runs in.
	 */
	private function stepOf(state: WalkState, edge: CallEdge, held: Null<String>): WalkStep {
		if (!_threads.runsHere(edge, listsOf(edge.file)) || leadsNowhere(edge, state.repeated)) return Skip;
		final live: Int = _conditions.carried(edge, state.valuation, state.ctx);
		if (live == 0) return Skip;
		final carriedDown: WalkFlags = stepFlags(state, edge, held);
		final repeats: Bool = carriedDown.repeated;
		// a short call run once on this path waits too little to count, and a sink leads nowhere
		if (blockingHere(edge, held))
			return counts(edge, held, repeats, state.valuation) && !briefUnder(state.under, edge) ? Blocks(repeats) : Skip;
		if (takesLock(edge)) return Skip;
		final next: Null<WalkState> = following(state, edge, live, carriedDown);
		return next == null ? Skip : Enter(next);
	}

	/**
	 * The state the call `edge` of `state` enters on `live`, under a hold of `flags.held` and repeating or not: its
	 * valuation bound, the judged hold carried into it (`LockDominance.carry`), and the classes it runs on
	 * (`AllocationSets.into`); null for a dispatch no class the receiver may be resolves to, which runs nothing here.
	 */
	private function following(state: WalkState, edge: CallEdge, live: Int, flags: WalkFlags): Null<WalkState> {
		final classes: Null<String> = _allocations?.receiverClasses(edge, state.self);
		if (_allocations?.dispatches(edge, classes) == false) return null;
		final valuation: String = _conditions.entered(edge, state.valuation);
		final under: Null<String> = _cost?.dominance.carry(state.under, edge);
		final self: Null<String> = _allocations?.into(edge, classes);
		return {
			key: stateKey(flags.held, edge.to, valuation, live, flags, under) + '|${self ?? ''}',
			id: edge.to,
			valuation: valuation,
			ctx: live,
			repeated: flags.repeated,
			way: flags.way,
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

	/** Whether calls from `id` may lead back to it; a walk longer than `CYCLE_WALK` functions says they may. */
	private function onCycle(id: String): Bool {
		final known: Null<Bool> = _cyclic[id];
		if (known != null) return known;
		final seen: Map<String, Bool> = [id => true];
		final queue: Array<String> = [id];
		var qi: Int = 0;
		var answer: Bool = false;
		while (qi < queue.length && !answer) {
			if (qi >= CYCLE_WALK) {
				answer = true;
				break;
			}
			// a value handed on that runs there closes a cycle too: `n.each(k -> walk(k))` walks a whole tree
			for (e in _graph.outEdges(queue[qi++])) if (_threads.runsHere(e, listsOf(e.file))) {
				if (e.to == id) answer = true;
				if (!seen.exists(e.to)) {
					seen[e.to] = true;
					queue.push(e.to);
				}
			}
		}
		_cyclic[id] = answer;
		return answer;
	}

	/**
	 * What the call `edge` of `state` carries down under a hold of `held`: whether a call on the way to its target
	 * repeats — bounded repetitions on one way multiply, and the call that takes them past the budget repeats — and the
	 * way's bounded repetitions so far.
	 */
	private function stepFlags(state: WalkState, edge: CallEdge, held: Null<String>): WalkFlags {
		final way: Null<BoundedWay> = state.repeated ? state.way : wayAt(edge, state.way);
		return { held: held, repeated: state.repeated || repeatsAt(edge) || way == null, way: way ?? state.way };
	}

	private static inline function stateKey(
		held: Null<String>, id: String, valuation: String, ctx: Int, flags: WalkFlags, under: Null<String>
	): String {
		final way: BoundedWay = flags.way;
		final bounded: String = way.entries.length > 0 ? '|${way.turns}x${way.cost}' : '';
		return '${held ?? ''}|$id|$valuation|$ctx${flags.repeated ? '|repeated' : bounded}|${under ?? ''}';
	}

}

/**
 * The states one `LockTaint.blockingEnds` walk entered, each once with every call into it, and the blocking calls found
 * from them: what `ends` groups by call site and lock. A state's predecessor -1 is the held call itself.
 */
@:nullSafety(Strict)
private final class EndGraph {

	/** The states entered, breadth first. */
	public final states: Array<WalkState> = [];

	/** For each state, the states whose calls enter it. */
	private final _preds: Array<Array<Int>> = [];

	/** For each state, the first state entering it and the call: the shortest way to it. */
	private final _first: Array<{ from: Int, edge: CallEdge }> = [];

	/** Each state's index, by its key. */
	private final _at: Map<String, Int> = [];

	/** Each blocking call found, the state whose call it is, and whether it repeats on that way. */
	private final _found: Array<{ from: Int, edge: CallEdge, repeated: Bool }> = [];

	/** The held call the walk starts at. */
	private final _call: CallEdge;

	public function new(call: CallEdge) {
		_call = call;
	}

	/** The call `edge` of the state at `from` enters `state`: a new state is queued, a known one gains a way in. */
	public function enter(state: WalkState, from: Int, edge: CallEdge): Void {
		final known: Null<Int> = _at[state.key];
		if (known != null) {
			if (!_preds[known].contains(from)) _preds[known].push(from);
			return;
		}
		_at[state.key] = states.length;
		states.push(state);
		_preds.push([from]);
		_first.push({ from: from, edge: edge });
	}

	/** The call `edge` of the state at `from` blocks, repeating on that way or not. */
	public function blocked(from: Int, edge: CallEdge, repeated: Bool): Void {
		_found.push({ from: from, edge: edge, repeated: repeated });
	}

	/**
	 * The blocking calls found, one per call site and lock waited for (`trail` builds each way's trail): the shortest
	 * way, repeated on any way, may repeat when it does or a function on any way into it is on a cycle (`onCycle`), and
	 * the functions every way to it passes.
	 */
	public function ends(
		onCycle: (String) -> Bool, trail: (Array<String>, CallEdge, Array<CallEdge>) -> BlockingTrail
	): Array<BlockingEnd> {
		final passing: Array<Array<String>> = dominators();
		final cyclic: Array<Bool> = cyclicWays(onCycle);
		final keys: Array<String> = [];
		final out: Array<BlockingEnd> = [];
		for (f in _found) {
			final way: BlockingTrail = wayTo(f.from, f.edge, trail);
			final key: String = '${MainSinkReport.siteKey(f.edge)}|${way.via ?? ''}';
			final passes: Array<String> = (f.from < 0 ? [] : passing[f.from]).concat([_call.to, f.edge.to]);
			final mayRepeat: Bool = f.repeated || onCycle(_call.to) || onCycle(f.edge.to) || f.from >= 0 && cyclic[f.from];
			final at: Int = keys.indexOf(key);
			if (at < 0) {
				keys.push(key);
				out.push({
					trail: way,
					repeated: f.repeated,
					mayRepeat: mayRepeat,
					passes: passes
				});
				continue;
			}
			final known: BlockingEnd = out[at];
			out[at] = {
				trail: known.trail,
				repeated: known.repeated || f.repeated,
				mayRepeat: known.mayRepeat || mayRepeat,
				passes: known.passes.filter(id -> passes.contains(id))
			};
		}
		return out;
	}

	/** The trail of the shortest way to the blocking call `end` of the state at `from` (`trail`). */
	private function wayTo(from: Int, end: CallEdge, trail: (Array<String>, CallEdge, Array<CallEdge>) -> BlockingTrail): BlockingTrail {
		final ids: Array<String> = [];
		final edges: Array<CallEdge> = [];
		var at: Int = from;
		while (at >= 0) {
			ids.unshift(states[at].id);
			edges.unshift(_first[at].edge);
			at = _first[at].from;
		}
		ids.push(end.to);
		edges.push(end);
		return trail(ids, end, edges);
	}

	/**
	 * For each state, the functions every way from the held call into it passes, its own included: the least fixed
	 * point of "a state's own function, and what all the states entering it share", breadth first so each sweep but the
	 * first only shrinks a set.
	 */
	private function dominators(): Array<Array<String>> {
		final known: Array<Null<Array<String>>> = [for (_ in states) null];
		var moved: Bool = true;
		while (moved) {
			moved = false;
			for (i => s in states) {
				var shared: Null<Array<String>> = null;
				for (p in _preds[i]) {
					final up: Null<Array<String>> = p < 0 ? [] : known[p];
					if (up == null) continue;
					final before: Null<Array<String>> = shared;
					shared = before == null ? up.copy() : before.filter(id -> up.contains(id));
				}
				final next: Array<String> = (shared ?? []).filter(id -> id != s.id).concat([s.id]);
				final old: Null<Array<String>> = known[i];
				if (old != null && old.length == next.length && old.foreach(id -> next.contains(id))) continue;
				known[i] = next;
				moved = true;
			}
		}
		return [for (k in known) k ?? []];
	}

	/**
	 * For each state, whether its function or one on some way into it is re-entered through a cycle of calls (`onCycle`):
	 * every call such a function makes may repeat, whichever way the walk took.
	 */
	private function cyclicWays(onCycle: (String) -> Bool): Array<Bool> {
		final cyclic: Array<Bool> = [for (s in states) onCycle(s.id)];
		var moved: Bool = true;
		while (moved) {
			moved = false;
			for (i in 0...states.length) if (!cyclic[i] && _preds[i].exists(p -> p >= 0 && cyclic[p])) {
				cyclic[i] = true;
				moved = true;
			}
		}
		return cyclic;
	}

}
