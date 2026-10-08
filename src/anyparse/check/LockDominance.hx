package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.query.CallGraph;
import anyparse.runtime.Span;

using Lambda;

/**
 * Outer-lock dominance: lock M is DOMINATED by lock L when every long hold of M — every hold spanning a call that blocks
 * long, or an unresolved call — holds L too, on the same object, at each such call (`MustHeld`). A thread holding L
 * then never waits long for M: the hold of M it may meet is no long one, since that one needs L. So a take of M made
 * while L is held on M's object is brief, wherever it is made — and the takes a hold of L itself spans in its window.
 *
 * Positive on every count. A lock is dominated by nothing when some hold of it may outlive its function, cannot be
 * traced, is the release of a hold begun elsewhere, or spans a long call on an object no path of stable fields names (`ObjectPaths`).
 */
@:nullSafety(Strict)
final class LockDominance {

	/** Bound on the rounds of `settle`: each round's answer is sound, the last one kept. */
	private static inline final ROUNDS: Int = 8;

	/** Each lock -> the locks that dominate it; filled by `settle`. */
	public final dominators: Map<String, Array<String>> = [];

	private final _sites: LockSites;
	private final _states: ThreadStates;
	private final _conditions: EdgeConditions;
	private final _repetition: CallRepetition;
	private final _must: MustHeld;
	private final _holds: Array<LockAcquire>;

	public function new(
		sites: LockSites, states: ThreadStates, conditions: EdgeConditions, repetition: CallRepetition, must: MustHeld,
		holds: Array<LockAcquire>
	) {
		_sites = sites;
		_states = states;
		_conditions = conditions;
		_repetition = repetition;
		_must = must;
		_holds = holds;
	}

	/**
	 * The taint asking which calls block LONG (`LockTaint.costed`), solved with `solve` and with `dominators` until they
	 * settle: fewer long holds can only free more takes, and every round is sound on its own. `solve` fills a fresh list
	 * of long locks on the taint it is handed. With `errors`, over the normal paths only: a call only an error path runs
	 * (`ErrorPaths`) leads nowhere.
	 */
	public function settle(
		taints: LockTaint, solve: (Array<String>, LockTaint) -> Void, ?errors: ErrorPaths
	): { long: Array<String>, costs: LockTaint } {
		var long: Array<String> = [];
		var costs: LockTaint = taints.costed(long, _repetition, this, errors);
		solve(long, costs);
		for (_ in 0...ROUNDS) {
			final judged: LockTaint = costs;
			if (!solveDominators(a -> longCallsOf(a, judged))) break;
			long = [];
			costs = taints.costed(long, _repetition, this, errors);
			solve(long, costs);
		}
		return { long: long, costs: costs };
	}

	/**
	 * The lock `take` takes dominated there (`dominators`): some dominator of it must-held on the object it takes it on,
	 * under `valuation` — or, null, under every valuation its function runs it on.
	 */
	public function dominated(take: CallEdge, valuation: Null<String>): Bool {
		final lock: Null<String> = _sites.lockOf(take);
		final at: Null<Span> = take.span;
		final by: Array<String> = lock == null ? [] : dominators[lock] ?? [];
		final object: Null<String> = _must.takeObject(take);
		if (at == null || by.length == 0 || object == null) return false;
		final under: Array<String> = valuation != null ? [valuation] : [
			for (s in _states.statesOf(take.from)) if (_conditions.carried(take, s.valuation, s.ctx) != 0) s.valuation
		];
		return under.length > 0
			&& under.foreach(v ->
				_must.at(take.from, v, take.file, at.from).exists(h -> MustHeld.objectOf(h) == object && by.contains(MustHeld.lockOf(h)))
			);
	}

	/**
	 * The hold `a` as `<lock>@<object>`: its lock and the object it is taken on, relative to its function (`MustHeld`);
	 * null for a lock no member names, or an object no path of stable fields names.
	 */
	public function holdOf(a: LockAcquire): Null<String> {
		final lock: Null<String> = a.lock;
		final object: Null<String> = _must.holdObject(a);
		return lock == null || object == null ? null : MustHeld.heldOn(lock, object);
	}

	/**
	 * The hold `under` (`holdOf`) as the callee of `call` sees it: its object carried onto the callee (`MustHeld.carried`);
	 * null when nothing says what that object is there, or when the callee may give the lock back (`MustHeld.mayRelease`).
	 */
	public function carry(under: Null<String>, call: CallEdge): Null<String> {
		if (under == null) return null;
		final lock: String = MustHeld.lockOf(under);
		final object: Null<String> = _must.carried(MustHeld.objectOf(under), call);
		return object == null || _must.mayRelease(lock, call.to) ? null : MustHeld.heldOn(lock, object);
	}

	/**
	 * Whether the take `take` waits for no long hold while the hold `under` is held: on that hold's object, a re-take of
	 * its lock by a take that may repeat it (`reentrant`), or a take of a lock it dominates (`dominators`).
	 */
	public function briefUnder(under: String, take: CallEdge, reentrant: Bool): Bool {
		final lock: Null<String> = _sites.lockOf(take);
		final held: String = MustHeld.lockOf(under);
		if (lock == null || _must.takeObject(take) != MustHeld.objectOf(under)) return false;
		return lock == held ? reentrant : (dominators[lock] ?? []).contains(held);
	}

	/**
	 * Solves `dominators` for the long holds `longAt` names: per hold, the offsets of its calls that block long, empty for
	 * a brief hold, null for a hold that rules dominance out. Returns whether any lock's dominators changed.
	 */
	private function solveDominators(longAt: (LockAcquire) -> Null<Array<Int>>): Bool {
		final found: Map<String, Array<String>> = [];
		final broken: Array<String> = [for (c in _sites.crossing) c.lock];
		for (a in _holds) {
			final lock: String = a.lock ?? '';
			if (lock == '' || a.uncontended || _sites.helpers.contains(a.edge.from) || broken.contains(lock)) continue;
			final positions: Null<Array<Int>> = longAt(a);
			// a brief hold leaves the lock free to be dominated by anything a long one holds
			if (positions != null && positions.length == 0) continue;
			final held: Null<Array<String>> = heldAtLong(a, lock, positions);
			if (held == null) {
				broken.push(lock);
				continue;
			}
			final known: Null<Array<String>> = found[lock];
			found[lock] = known == null ? held : known.filter(l -> held.contains(l));
		}
		var changed: Bool = false;
		for (lock in [for (l in found.keys()) l].concat(broken)) {
			final next: Array<String> = broken.contains(lock) ? [] : found[lock] ?? [];
			next.sort(Reflect.compare);
			if ((dominators[lock] ?? []).join('\n') != next.join('\n')) changed = true;
			dominators[lock] = next;
		}
		return changed;
	}

	/**
	 * The other locks the long hold `a` of `lock` holds, on its object, at every offset of `positions` under every
	 * valuation its take runs under; null when it takes its lock on an object no path of stable fields names, or `positions`
	 * itself is null.
	 */
	private function heldAtLong(a: LockAcquire, lock: String, positions: Null<Array<Int>>): Null<Array<String>> {
		final object: Null<String> = _must.holdObject(a);
		if (positions == null || positions.length > 0 && object == null) return null;
		var meet: Null<Array<String>> = null;
		for (state in _states.statesOf(a.edge.from)) if (_conditions.carried(
			a.edge, state.valuation, state.ctx
		) != 0) for (at in positions) {
			final held: Array<String> = [
				for (h in _must.at(a.edge.from, state.valuation, a.edge.file, at, lock))
					if (MustHeld.objectOf(h) == object && MustHeld.lockOf(h) != lock) MustHeld.lockOf(h)
			];
			final known: Null<Array<String>> = meet;
			meet = known == null ? held : known.filter(l -> held.contains(l));
		}
		return meet ?? [];
	}

	/**
	 * Where the hold `a` blocks long under `costs`: the starts of its calls that do, and of its unresolved ones but a bare
	 * `shortSinks` name run once under the hold; null for a hold that may outlive its function or could not be traced.
	 */
	private function longCallsOf(a: LockAcquire, costs: LockTaint): Null<Array<Int>> {
		if (LongLockExplain.leaks(a) || a.untraced) return null;
		final at: Array<Int> = [
			for (b in costs.blockingCalls(a, costs.reentrantHeld(a))) b.edge.span?.from ?? -1
		];
		for (c in a.blindCalls) if (!costs.briefBlind(a, c)) at.push(c.span.from);
		return at;
	}

}
