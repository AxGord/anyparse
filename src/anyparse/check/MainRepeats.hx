package anyparse.check;

import anyparse.query.CallGraph;

using Lambda;

/**
 * Which main-thread STATES — a function under a valuation of its tracked parameters (`ThreadStates`) — may run more than
 * once per run of the main thread, and which repeating calls own the short calls below them (`CallRepetition`). Read
 * over the states, not the functions: a call its conditions rule out under the valuation a caller hands down
 * (`EdgeConditions.carried`) carries no repetition there — TM's `DrillVOModel.loadDrillData` calls `loadXML(path, false,
 * …)`, whose `if (checkLimits)` SQL count never runs on that way, however many drills the session planner loops over.
 */
@:nullSafety(Strict)
final class MainRepeats {

	/** `<id>|<valuation>` of every main-thread state some repeating call reaches. */
	private final _repeated: Map<String, Bool> = [];

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
		solve();
	}

	/** Whether some main-thread state of `edge`'s function that runs `edge` may itself run more than once. */
	public function repeatedAt(edge: CallEdge): Bool {
		return mainStates(edge.from).exists(v -> _repeated.exists(key(edge.from, v)) && runsFrom(edge, v) != null);
	}

	/**
	 * The nearest calls or registrations that repeat on the way down to the main-thread call `edge`: walking up from the
	 * states of its function that run it, through the calls that enter each state from a caller's state, each one that
	 * repeats (`CallRepetition.repeated`), with the functions from its target down to `edge`'s function; the walk goes on
	 * past none of them. Nearest first, then in order of their sites.
	 */
	public function ownersOf(edge: CallEdge): Array<{ edge: CallEdge, path: Array<String> }> {
		final out: Array<{ edge: CallEdge, path: Array<String> }> = [];
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
			// a registered value runs as a run of its own: nothing up its registration repeats it
			for (e in _graph.inEdges(at.id)) if (
				e.kind != Contains && _runs(e) && !_repetition.registered(e)
			) for (v in mainStates(e.from)) {
				if (runsFrom(e, v) != at.valuation) continue;
				final caller: String = key(e.from, v);
				if (_repetition.repeated(e)) {
					if (!out.exists(o -> o.edge == e)) out.push({ edge: e, path: path });
				} else if (!down.exists(caller)) {
					down[caller] = [e.from].concat(path);
					queue.push({ id: e.from, valuation: v });
				}
			}
		}
		out.sort((a, b) ->
			a.path.length != b.path.length
				? a.path.length - b.path.length
				: Reflect.compare(
					'${a.edge.file}:${a.edge.span?.from ?? -1}:${a.edge.to}', '${b.edge.file}:${b.edge.span?.from ?? -1}:${b.edge.to}'
				)
		);
		return out;
	}

	/** Every state some repeating main-thread edge enters, and every state reached from one through the main thread's edges. */
	private function solve(): Void {
		final queue: Array<{ id: String, valuation: String }> = [];
		for (id => _ in _graph.nodes) for (v in mainStates(id)) for (e in _graph.outEdges(id)) {
			final entered: Null<String> = e.kind != Contains && _runs(e) && _repetition.repeated(e) ? runsFrom(e, v) : null;
			if (entered != null) mark(e.to, entered, queue);
		}
		var qi: Int = 0;
		while (qi < queue.length) {
			final at: { id: String, valuation: String } = queue[qi++];
			for (e in _graph.outEdges(at.id)) if (e.kind != Contains && _runs(e)) {
				final entered: Null<String> = runsFrom(e, at.valuation);
				if (entered != null) mark(e.to, entered, queue);
			}
		}
	}

	private function mark(id: String, valuation: String, queue: Array<{ id: String, valuation: String }>): Void {
		final k: String = key(id, valuation);
		if (_repeated.exists(k)) return;
		_repeated[k] = true;
		queue.push({ id: id, valuation: valuation });
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
