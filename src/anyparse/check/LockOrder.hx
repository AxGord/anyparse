package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.LockSites.LockAcquire;
import anyparse.check.ThreadSafety.FindingFamily;
import anyparse.query.CallGraph;

using Lambda;

/**
 * One way a thread can be in a function: entered on `ctx` under `valuation` (`EdgeConditions`) holding the locks `held`
 * (sorted), keyed by all four (`key`), through every call that reaches it (`arrivals`) — none for an entry point.
 */
private typedef HeldState = {
	final id: String;
	final ctx: Int;
	final valuation: String;
	final held: Array<String>;
	final key: String;
	final arrivals: Array<Arrival>;
}

/** One way into a state: the call `via` of the `parent` state. */
private typedef Arrival = {
	final parent: HeldState;
	final via: CallEdge;
}

/** How a lock held on entering a state came to be held: the function that took it, where it called out, and the path from it. */
private typedef Climb = {
	final holder: String;
	final anchor: Null<CallEdge>;
	final prefix: Array<String>;
}

/** One "holds A, then takes B" step: the state that makes it, the call there that takes B, and the context it runs on. */
private typedef OrderStep = {
	final state: HeldState;
	final take: CallEdge;
	final ctx: Int;
	final held: String;
	final taken: String;
}

/**
 * A step as its finding tells it: where the hold of the first lock calls toward the take (`anchor`), the function holding
 * that lock (`holder`) and the path from it to the take — what orders two steps of one pair (`precedes`).
 */
private typedef RankedStep = {
	final step: OrderStep;
	final anchor: CallEdge;
	final holder: String;

	/** The member `holder` belongs to (`ThreadSafety.memberOf`): what a finding keys by. */
	final member: String;
	final path: Array<String>;
}

/**
 * The lock-order (ABBA) finding of `thread-safety`: some thread holds lock A and takes lock B while another holds B
 * and takes A, one on the main thread and the other on a background one. Each then waits forever for the lock the
 * other holds.
 *
 * The order is read off a walk of thread STATES — a function, the context it runs in, and the locks held on entering it —
 * from every entry point: a function no invocation reaches, a callback on the context its registration runs
 * (`ThreadStates.edgeContext`), and a cycle of calls nothing else enters, each holding nothing, on a context
 * `ThreadStates` gives it. A call adds the locks its function holds there (the windows
 * of its own holds, a multi-lock helper's included) and enters its target with them; a callback never inherits them.
 * A take of B with A held is a step from A to B; a take of a lock already held is a re-take on the thread that holds it,
 * and orders nothing, so one consistent order through re-entrant re-takes stays quiet. A state carries the valuation of
 * its function's tracked parameters too: a call runs from it only where `EdgeConditions` lets it, on the threads it
 * lets it, and a hold of the body counts only where its own take runs.
 *
 * Positive on every count, so as to report only a real pair: both locks named (`LockSites.lockOf`; an unknown lock
 * orders nothing), no hold the owner's constructor's (`LockAcquire.uncontended`), and one step main, the other
 * background. Two background steps are not reported — one worker may run them both — nor two main ones, one thread.
 * The lock of one member is one lock, so two objects' instances of it (`a.m` then `b.m`) order nothing here. What the
 * walk over-approximates: a lock a caller holds is taken to be held throughout the callee, a release there included.
 */
@:nullSafety(Strict)
final class LockOrder {

	/** Bound on the states the walk visits: past it the run reports no inversion at all rather than a partial answer. */
	private static inline final STATE_CAP: Int = 200000;

	/** `<file>:<start>` of each call -> the named locks its function holds there, by the holds of its own body, each with its take. */
	private final _heldAt: Map<String, Array<{ lock: String, take: CallEdge }>> = [];

	/** `<file>:<start>` of each take -> the named locks it takes. */
	private final _takenAt: Map<String, Array<String>> = [];

	/** Each order, by `<held>\n<taken>`: every step making it, ranked only once its order turns out reported (`rankStep`). */
	private final _steps: Map<String, Array<OrderStep>> = [];

	/** The keys of `_steps`, in the order the walk first made each. */
	private final _order: Array<String> = [];

	private final _graph: CallGraph;
	private final _conditions: EdgeConditions;

	/**
	 * The holds of `holds` the walk reads — each of a named lock, none the owner's constructor's — and the `conditions`
	 * that say which calls run from a state.
	 */
	public function new(graph: CallGraph, conditions: EdgeConditions, holds: Array<LockAcquire>) {
		_graph = graph;
		_conditions = conditions;
		for (a in holds) admit(a);
	}

	/**
	 * Walks every state a thread can reach — entered at a graph entry point (no invocation reaches it) on the contexts
	 * `threads` gives it, or as a callback on the context its registration runs (`ThreadStates.edgeContext`) unless
	 * `inertRef` says the value never runs from there — collecting each take of a lock some other lock is held at, then
	 * reports one finding per pair of locks taken in both orders by steps on different threads (`main` / `bg`: the
	 * context bits of each), anchored at the main-thread step and naming both chains. A function `threads` gives no
	 * context runs nowhere.
	 */
	public function report(threads: ThreadStates, inertRef: (CallEdge) -> Bool, main: Int, bg: Int, chainCap: Int): Array<Violation> {
		final contexts: Map<String, Int> = threads.contexts;
		final seen: Map<String, HeldState> = [];
		final reached: Map<String, HeldState> = [];
		final queue: Array<HeldState> = [];
		function follow(state: HeldState): Void {
			final known: Null<HeldState> = seen[state.key];
			// a state met again keeps the new way in: which function holds a lock must not hang on the walk's order
			if (known != null) {
				for (arrival in state.arrivals) known.arrivals.push(arrival);
				return;
			}
			seen[state.key] = state;
			if (!reached.exists(state.id)) reached[state.id] = state;
			queue.push(state);
		}
		function enter(id: String, ctx: Int): Void {
			if (ctx == 0) return;
			follow(heldState(id, ctx, _conditions.unknown(id), [], null));
		}
		for (id => node in _graph.nodes) if (isEntry(id, node)) enter(id, contexts[id] ?? 0);
		for (e in _graph.edges) if (runsCallback(e, inertRef)) enter(e.to, threads.edgeContext(e));
		var qi: Int = 0;
		while (true) {
			while (qi < queue.length) {
				if (queue.length > STATE_CAP) return [capReached()];
				visit(queue[qi++], follow);
			}
			// a cycle of calls nothing outside it calls is entered anywhere, holding nothing, as `contexts` assumed
			final before: Int = queue.length;
			for (id => node in _graph.nodes) if (!(node.isExternal || reached.exists(id))) enter(id, contexts[id] ?? 0);
			if (queue.length == before) break;
		}
		return inversions(main, bg, chainCap);
	}

	/** Whether `id` (its `node`) is an entry point of the walk: a function of the run no invocation reaches. */
	private function isEntry(id: String, node: FnNode): Bool {
		return !node.isExternal && !_graph.inEdges(id).exists(e -> e.kind.isInvocation());
	}

	/** Whether the `Ref` edge `e` hands a function of the run to code that runs it (`inertRef` says which never do). */
	private function runsCallback(e: CallEdge, inertRef: (CallEdge) -> Bool): Bool {
		return e.kind == Ref && _graph.node(e.to)?.isExternal == false && !inertRef(e);
	}

	/** Indexes the hold `a` — its take and the calls its window spans — when it is of a named lock and no constructor's own. */
	private function admit(a: LockAcquire): Void {
		final named: Null<String> = a.lock;
		if (named == null || a.uncontended) return;
		final lock: String = named;
		add(_takenAt, siteKey(a.edge), lock);
		for (e in a.window) {
			final key: String = siteKey(e);
			final known: Array<{ lock: String, take: CallEdge }> = _heldAt[key] ?? [];
			if (!known.exists(h -> h.lock == lock && h.take == a.edge)) known.push({ lock: lock, take: a.edge });
			_heldAt[key] = known;
		}
	}

	/**
	 * Runs the calls of `state`'s function that run from it (`EdgeConditions.carried`): records the steps their takes
	 * make, and enters the functions they call. A hold of the body counts at a call only where its own take runs too.
	 */
	private function visit(state: HeldState, enter: (HeldState) -> Void): Void {
		for (e in _graph.outEdges(state.id)) if (e.kind.isInvocation()) {
			final ctx: Int = _conditions.carried(e, state.valuation, state.ctx);
			if (ctx == 0) continue;
			final key: String = siteKey(e);
			final held: Array<String> = state.held.copy();
			for (h in _heldAt[key] ?? []) if (!held.contains(h.lock) && _conditions.carried(h.take, state.valuation, state.ctx) != 0)
				held.push(h.lock);
			held.sort(Reflect.compare);
			// a lock held already is a re-take, on the lock of one member: no order between two locks
			for (taken in _takenAt[key] ?? []) if (!held.contains(taken)) for (h in held) record({
				state: state,
				take: e,
				ctx: ctx,
				held: h,
				taken: taken
			});
			if (_graph.node(e.to)?.isExternal == false) enter(heldState(e.to, ctx, _conditions.bind(e, state.valuation), held, {
				parent: state,
				via: e
			}));
		}
	}

	/** Keeps `step` among the witnesses of its order; which one a finding names is decided once the walk is done (`crossThread`). */
	private function record(step: OrderStep): Void {
		final key: String = '${step.held}\n${step.taken}';
		final known: Null<Array<OrderStep>> = _steps[key];
		if (known == null) {
			_steps[key] = [step];
			_order.push(key);
		} else
			known.push(step);
	}

	/** One finding per pair of locks whose two orders some main-thread step and some background step make. */
	private function inversions(main: Int, bg: Int, chainCap: Int): Array<Violation> {
		final violations: Array<Violation> = [];
		final done: Array<String> = [];
		final memo: Map<String, Climb> = [];
		final rank: (OrderStep) -> RankedStep = step -> rankStep(step, memo);
		for (key in _order) {
			final locks: Array<String> = key.split('\n');
			final back: String = '${locks[1]}\n${locks[0]}';
			if (done.contains(back)) continue;
			final pair: Null<{ main: RankedStep, bg: RankedStep }> = crossThread(_steps[key] ?? [], _steps[back] ?? [], main, bg, rank);
			if (pair == null) continue;
			done.push(key);
			final m: RankedStep = pair.main;
			violations.push({
				file: m.anchor.file,
				span: m.anchor.span,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: 'lock-order inversion: ${told(m, chainCap)} on the main thread, while ${told(pair.bg, chainCap)} on a background'
				+ ' thread — each can wait forever for the lock the other holds',
				data: {
					family: FindingFamily.OrderInversion,
					member: m.member,
					subject: ThreadSafety.subjectOf(locks),
					chain: m.path
				}
			});
		}
		return violations;
	}

	/**
	 * `step` ranked: the call where the hold of its first lock A first calls toward the take, the function
	 * F holding A — the one on the step's path that took A itself — and the whole path from F to the take.
	 */
	private function rankStep(step: OrderStep, memo: Map<String, Climb>): RankedStep {
		final up: Climb = climb(step.state, step.held, memo, []);
		return {
			step: step,
			anchor: up.anchor ?? step.take,
			holder: up.holder,
			member: ThreadSafety.memberOf(_graph, up.holder),
			path: up.prefix.concat([step.take.to])
		};
	}

	/**
	 * Who holds `held` on entering `state`: the state itself when it does not hold it on entry (it takes the lock), else —
	 * over EVERY way into it, a way back into a state on `onPath` aside — the way whose holder precedes (`precedes`), with
	 * the call where that holder's hold first calls out. `memo` keeps each state's answer for one lock.
	 */
	private function climb(state: HeldState, held: String, memo: Map<String, Climb>, onPath: Array<String>): Climb {
		final key: String = '$held\n${state.key}';
		final known: Null<Climb> = memo[key];
		if (known != null) return known;
		var best: Null<Climb> = null;
		if (state.held.contains(held)) for (arrival in state.arrivals) if (!onPath.contains(arrival.parent.key)) {
			final up: Climb = climb(arrival.parent, held, memo, onPath.concat([state.key]));
			final found: Climb = { holder: up.holder, anchor: up.anchor ?? arrival.via, prefix: up.prefix.concat([state.id]) };
			final current: Null<Climb> = best;
			if (current == null || climbPrecedes(found, current)) best = found;
		}
		final out: Climb = best ?? { holder: state.id, anchor: null, prefix: [state.id] };
		memo[key] = out;
		return out;
	}

	/** Whether the way `a` into a state precedes the way `b` (`earlier`, by the members of their holders). */
	private function climbPrecedes(a: Climb, b: Climb): Bool {
		return earlier(
			ThreadSafety.memberOf(_graph, a.holder), a.anchor, a.prefix, ThreadSafety.memberOf(_graph, b.holder), b.anchor, b.prefix
		);
	}

	/** `<file>:<start>` of `edge`'s site. */
	private static inline function siteKey(edge: CallEdge): String {
		return '${edge.file}:${edge.span?.from ?? -1}';
	}

	/** A state of `id` on `ctx` under `valuation` holding `held`, entered by `arrival` (none for an entry point). */
	private static function heldState(id: String, ctx: Int, valuation: String, held: Array<String>, arrival: Null<Arrival>): HeldState {
		return {
			id: id,
			ctx: ctx,
			valuation: valuation,
			held: held,
			key: '$id|$ctx|$valuation|${held.join('\n')}',
			arrivals: arrival == null ? [] : [arrival]
		};
	}

	/** `"F" holds "A" and then takes "B" (F -> ... -> take)` for `ranked`, the path capped at `cap` (`ThreadSafety.elided`). */
	private static function told(ranked: RankedStep, cap: Int): String {
		final step: OrderStep = ranked.step;
		return '"${ranked.holder}" holds "${step.held}" and then takes "${step.taken}" (${ThreadSafety.elided(ranked.path, cap)})';
	}

	/** The one finding of a run whose states overflow `STATE_CAP`: the order went unchecked, which is no clean bill. */
	private static function capReached(): Violation {
		return {
			file: '',
			span: null,
			rule: 'thread-safety',
			severity: Severity.Info,
			message: 'lock order not checked: the call graph holds more than $STATE_CAP (function, held locks) states'
		};
	}

	/**
	 * The pair of `ab` and `ba` steps, one on the main thread (`main`) and the other on a background
	 * one (`bg`), whose main step precedes every other main step (`precedes`), with the least background
	 * step of the other order: one inversion, one anchor, whatever order the walk met the steps in.
	 */
	private static function crossThread(
		ab: Array<OrderStep>, ba: Array<OrderStep>, main: Int, bg: Int, rank: (OrderStep) -> RankedStep
	): Null<{ main: RankedStep, bg: RankedStep }> {
		var best: Null<{ main: RankedStep, bg: RankedStep }> = null;
		for (side in [{ mains: ab, bgs: ba }, { mains: ba, bgs: ab }]) {
			final m: Null<RankedStep> = least(side.mains, main, rank);
			final b: Null<RankedStep> = least(side.bgs, bg, rank);
			if (m == null || b == null) continue;
			final found: { main: RankedStep, bg: RankedStep } = { main: m, bg: b };
			final current: Null<{ main: RankedStep, bg: RankedStep }> = best;
			if (current == null || precedes(found.main, current.main)) best = found;
		}
		return best;
	}

	/** The step of `steps` running on a context of `mask` that precedes every other such step; null with none. */
	private static function least(steps: Array<OrderStep>, mask: Int, rank: (OrderStep) -> RankedStep): Null<RankedStep> {
		var out: Null<RankedStep> = null;
		for (step in steps) if (step.ctx & mask != 0) {
			final s: RankedStep = rank(step);
			final known: Null<RankedStep> = out;
			if (known == null || precedes(s, known)) out = s;
		}
		return out;
	}

	/**
	 * Whether `a` precedes `b`: by the member holding the first lock (`ThreadSafety.memberOf`), then the anchor's file and
	 * offset, then the path — a total order over what a finding says, so the step a report names does not depend on walk order.
	 */
	private static inline function precedes(a: RankedStep, b: RankedStep): Bool {
		return earlier(a.member, a.anchor, a.path, b.member, b.anchor, b.path);
	}

	/** The order `precedes` and `climbPrecedes` share: by member, then the anchor's file and offset, then the path. */
	private static function earlier(
		memberA: String, anchorA: Null<CallEdge>, pathA: Array<String>, memberB: String, anchorB: Null<CallEdge>, pathB: Array<String>
	): Bool {
		final fileA: String = anchorA?.file ?? '';
		final fileB: String = anchorB?.file ?? '';
		final atA: Int = anchorA?.span?.from ?? -1;
		final atB: Int = anchorB?.span?.from ?? -1;
		return if (memberA != memberB)
			memberA < memberB
		else if (fileA != fileB)
			fileA < fileB
		else if (atA != atB)
			atA < atB
		else
			pathA.join('\n') < pathB.join('\n');
	}

	private static function add(into: Map<String, Array<String>>, key: String, lock: String): Void {
		final known: Array<String> = into[key] ?? [];
		if (!known.contains(lock)) known.push(lock);
		into[key] = known;
	}

}
