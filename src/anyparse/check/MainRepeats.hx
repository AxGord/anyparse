package anyparse.check;

import anyparse.query.CallGraph;

using Lambda;

/** A repeating call up the main thread's way to a call, and the functions from its target down to the call's own. */
typedef RepeatOwner = {
	final edge: CallEdge;
	final path: Array<String>;
}

/** What the main thread's ways up from one call say about how often it runs (`MainRepeats.climb`). */
typedef MainClimb = {
	/**
	 * The nearest calls that repeat on each way (`CallRepetition.repeated`), and each value marshalled onto the main
	 * thread on the way (`CallRepetition.marshalled`) — nearest first, then by file, offset and target.
	 */
	final owners: Array<RepeatOwner>;

	/**
	 * The functions on the ways the walk only ASSUMES run on the main thread (`ThreadStates.assumed`), the entry
	 * point and static initializers aside: no call the graph resolves runs them, so how often they run is unknown.
	 */
	final assumed: Array<String>;

	/** Whether a way ends at a registration (`CallRepetition.registered`): the value runs once per event the runtime dispatches. */
	final registered: Bool;
}

/**
 * How often the main thread may run a call, read over the main-thread STATES — a function under a valuation of its
 * tracked parameters (`ThreadStates`) — upward from the call. A call its conditions rule out under the valuation a caller
 * hands down (`EdgeConditions.carried`) carries no repetition there — TM's `DrillVOModel.loadDrillData` calls
 * `loadXML(path, false, …)`, whose `if (checkLimits)` SQL count never runs on that way, however many drills the session
 * planner loops over.
 *
 * Positive: a call runs once per main-thread run only when every way up from it ends at the entry point or at a
 * registration (`registers`) through calls none of which repeats. A way that meets a repeating call names it as an
 * owner; one that meets a value marshalled onto the main thread (`marshals`) names that registration, since the posts
 * come from a thread this walk does not count — TM's `ThreadsUtil` runs every pending task in one frame; one that ends
 * at a function nothing the graph resolves runs, but the entry point, says so (`MainClimb.assumed`).
 */
@:nullSafety(Strict)
final class MainRepeats {

	private final _graph: CallGraph;
	private final _repetition: CallRepetition;
	private final _states: ThreadStates;
	private final _conditions: EdgeConditions;
	private final _runs: (CallEdge) -> Bool;

	/** Over the main-thread states of `states`, the edges `runs` admits, repetition by `repetition`. */
	public function new(
		graph: CallGraph, repetition: CallRepetition, states: ThreadStates, conditions: EdgeConditions, runs: (CallEdge) -> Bool
	) {
		_graph = graph;
		_repetition = repetition;
		_states = states;
		_conditions = conditions;
		_runs = runs;
	}

	/**
	 * Walks up from the states of `edge`'s function that run it, through the calls that enter each state from a
	 * caller's state, past none that repeats (`CallRepetition.repeated`) and no registration: what repeats the call on
	 * each way, which of the functions on them only an assumption runs, and whether a way ends at a registration.
	 */
	public function climb(edge: CallEdge): MainClimb {
		final owners: Array<RepeatOwner> = [];
		final assumed: Array<String> = [];
		var registered: Bool = false;
		final down: Map<String, Array<String>> = [];
		final queue: Array<{ id: String, valuation: String }> = [];
		for (v in mainStates(edge.from)) if (runsFrom(edge, v) != null) {
			down[key(edge.from, v)] = [edge.from];
			queue.push({ id: edge.from, valuation: v });
		}
		var qi: Int = 0;
		while (qi < queue.length) {
			final at: { id: String, valuation: String } = queue[qi++];
			final path: Array<String> = down[key(at.id, at.valuation)] ?? [at.id];
			if (_states.assumed.exists(at.id) && !runsOnceAtStart(at.id) && !assumed.contains(at.id)) assumed.push(at.id);
			for (e in _graph.inEdges(at.id)) if (e.kind != Contains && _runs(e)) {
				// a registered value runs as a run of its own: nothing up its registration repeats it
				if (_repetition.registered(e)) {
					registered = true;
					continue;
				}
				// a marshalled value runs once per post, posted from a thread this walk does not count
				if (_repetition.marshalled(e)) {
					if (runsFrom(e, at.valuation) == at.valuation) own(owners, e, path);
					continue;
				}
				for (v in mainStates(e.from)) if (runsFrom(e, v) == at.valuation) {
					final caller: String = key(e.from, v);
					if (_repetition.repeated(e)) {
						own(owners, e, path);
					} else if (!down.exists(caller)) {
						down[caller] = [e.from].concat(path);
						queue.push({ id: e.from, valuation: v });
					}
				}
			}
		}
		owners.sort(nearestFirst);
		return { owners: owners, assumed: assumed, registered: registered };
	}

	/** `e` an owner of the call `path` walks down to, once. */
	private static function own(owners: Array<RepeatOwner>, e: CallEdge, path: Array<String>): Void {
		if (!owners.exists(o -> o.edge == e)) owners.push({ edge: e, path: path });
	}

	/** Nearest first, then by file, by offset as a number — an unrelated edit before both moves neither past the other — and by target. */
	private static function nearestFirst(a: RepeatOwner, b: RepeatOwner): Int {
		final at: Int = a.edge.span?.from ?? -1;
		final bt: Int = b.edge.span?.from ?? -1;
		return if (a.path.length != b.path.length)
			a.path.length - b.path.length
		else if (a.edge.file != b.edge.file)
			Reflect.compare(a.edge.file, b.edge.file)
		else if (at != bt)
			at - bt
		else
			Reflect.compare(a.edge.to, b.edge.to);
	}

	/** Whether `id` is code the runtime runs once per program: the entry point, or a type's static initializers (`CallGraph.STATIC_INIT_NAME`). */
	private function runsOnceAtStart(id: String): Bool {
		final name: Null<String> = _graph.node(id)?.name;
		return name == ThreadSafety.ENTRY_POINT || name == CallGraph.STATIC_INIT_NAME;
	}


	/**
	 * The valuation the edge `e` enters its target under from its function's state `valuation` on the main thread: the
	 * values a call hands down (`EdgeConditions.bind`), nothing known for a registered callback; null when a condition
	 * around it rules it out there.
	 */
	private function runsFrom(e: CallEdge, valuation: String): Null<String> {
		if (e.kind == Ref) return _conditions.unknown(e.to);
		return _conditions.carried(e, valuation, ThreadSafety.CTX_MAIN) == 0 ? null : _conditions.bind(e, valuation);
	}

	/** The valuations of the main-thread states of `id`. */
	private function mainStates(id: String): Array<String> {
		return [
			for (s in _states.statesOf(id)) if (s.ctx & ThreadSafety.CTX_MAIN != 0) s.valuation
		];
	}

	private static inline function key(id: String, valuation: String): String {
		return '$id|$valuation';
	}

}
