package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.LockSites.LockAcquire;
import anyparse.query.CallGraph;

using Lambda;

/**
 * One way a thread can be in a function: entered on `ctx` under `valuation` (`EdgeConditions`) holding the locks `held`
 * (sorted), through the call `via` of the `parent` state — none for an entry point.
 */
private typedef HeldState = {
	final id: String;
	final ctx: Int;
	final valuation: String;
	final held: Array<String>;
	final parent: Null<HeldState>;
	final via: Null<CallEdge>;
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

	/** Each step, by `<held>\n<taken>`, at most one per context bit of its state. */
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
			final key: String = '${state.id}|${state.ctx}|${state.valuation}|${state.held.join('\n')}';
			if (seen.exists(key)) return;
			seen[key] = state;
			if (!reached.exists(state.id)) reached[state.id] = state;
			queue.push(state);
		}
		function enter(id: String, ctx: Int): Void {
			if (ctx == 0) return;
			follow({
				id: id,
				ctx: ctx,
				valuation: _conditions.unknown(id),
				held: [],
				parent: null,
				via: null
			});
		}
		for (id => node in _graph.nodes) if (!node.isExternal && !_graph.inEdges(id).exists(e -> e.kind.isInvocation()))
			enter(id, contexts[id] ?? 0);
		for (e in _graph.edges) if (e.kind == Ref && _graph.node(e.to)?.isExternal == false && !inertRef(e))
			enter(e.to, threads.edgeContext(e));
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
			if (_graph.node(e.to)?.isExternal == false) enter({
				id: e.to,
				ctx: ctx,
				valuation: _conditions.bind(e, state.valuation),
				held: held,
				parent: state,
				via: e
			});
		}
	}

	/** Keeps `step` as the witness of its order for each context bit no earlier step of that order has. */
	private function record(step: OrderStep): Void {
		final key: String = '${step.held}\n${step.taken}';
		final known: Null<Array<OrderStep>> = _steps[key];
		if (known == null) {
			_steps[key] = [step];
			_order.push(key);
		} else if (step.ctx & ~known.fold((s, bits) -> bits | s.ctx, 0) != 0) {
			known.push(step);
		}
	}

	/** One finding per pair of locks whose two orders some main-thread step and some background step make. */
	private function inversions(main: Int, bg: Int, chainCap: Int): Array<Violation> {
		final violations: Array<Violation> = [];
		final done: Array<String> = [];
		for (key in _order) {
			final locks: Array<String> = key.split('\n');
			final back: String = '${locks[1]}\n${locks[0]}';
			if (done.contains(back)) continue;
			final pair: Null<{ main: OrderStep, bg: OrderStep }> = crossThread(_steps[key] ?? [], _steps[back] ?? [], main, bg);
			if (pair == null) continue;
			done.push(key);
			final m: { text: String, anchor: CallEdge } = describe(pair.main, chainCap);
			final b: { text: String, anchor: CallEdge } = describe(pair.bg, chainCap);
			violations.push({
				file: m.anchor.file,
				span: m.anchor.span,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: 'lock-order inversion: ${m.text} on the main thread, while ${b.text} on a background thread — each can wait'
				+ ' forever for the lock the other holds'
			});
		}
		return violations;
	}

	/**
	 * `"F" holds "A" and then takes "B" (F -> ... -> take)` for `step`, with the call where F's hold of A first calls
	 * toward the take: F is the function on the step's path that took A itself.
	 */
	private function describe(step: OrderStep, cap: Int): { text: String, anchor: CallEdge } {
		final path: Array<String> = [step.take.to];
		var anchor: CallEdge = step.take;
		var cursor: HeldState = step.state;
		while (true) {
			path.unshift(cursor.id);
			final parent: Null<HeldState> = cursor.parent;
			final via: Null<CallEdge> = cursor.via;
			if (parent == null || via == null || !cursor.held.contains(step.held)) break;
			anchor = via;
			cursor = parent;
		}
		return {
			text: '"${cursor.id}" holds "${step.held}" and then takes "${step.taken}" (${ThreadSafety.elided(path, cap)})',
			anchor: anchor
		};
	}

	/** `<file>:<start>` of `edge`'s site. */
	private static inline function siteKey(edge: CallEdge): String {
		return '${edge.file}:${edge.span?.from ?? -1}';
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

	/** The first pair of `ab` and `ba` steps one of which runs on the main thread and the other on a background one. */
	private static function crossThread(
		ab: Array<OrderStep>, ba: Array<OrderStep>, main: Int, bg: Int
	): Null<{ main: OrderStep, bg: OrderStep }> {
		for (x in ab) for (y in ba) {
			if (x.ctx & main != 0 && y.ctx & bg != 0) return { main: x, bg: y };
			if (y.ctx & main != 0 && x.ctx & bg != 0) return { main: y, bg: x };
		}
		return null;
	}

	private static function add(into: Map<String, Array<String>>, key: String, lock: String): Void {
		final known: Array<String> = into[key] ?? [];
		if (!known.contains(lock)) known.push(lock);
		into[key] = known;
	}

}
