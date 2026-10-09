package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.HoldGrade.FoldHold;
import anyparse.check.HoldGrade.GradedHold;
import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockTaint.BlockingTrail;

using Lambda;

/** Why one long call of a warned hold is long: a wait for another lock, a sink call finding (a) warns of, or neither. */
private enum FoldReason {
	Waits(lock: String);

	/**
	 * Long by the sink call `key` (`MainSinkReport.siteKey`), which runs more than once under the hold along its trail
	 * (`repeated`) or not, or may (`mayRepeat`, through a cycle of calls on the way), reached through the functions `way`.
	 */
	Site(key: String, repeated: Bool, mayRepeat: Bool, way: Array<String>);
	Uncovered;
}

/** Where a warned hold stands in `RootCauseFold.fold`: not yet decided, kept a warning, or folded onto others. */
private enum abstract FoldState(Int) {
	final Open = 0;
	final Kept = 1;
	final Folded = 2;
}

/** A warned hold (by index) long by a sink call, and whether that call runs more than once under it. */
private typedef SiteDoer = {
	final at: Int;
	final repeated: Bool;
}

/**
 * One warning per root cause across holds: a hold finding (b) warning whose every long call is long only through what
 * another warned hold already reports turns info, naming those holds. A call counts as covered when it waits for a lock
 * every hold making that lock long has its long work reported — its own warning, kept or folded, or the warning its info
 * finding names (TM's tree lock, held long by `FolderWatcher.updateInternal`, which `StandardFileSystem.saveXML` waits
 * for under the mutation lock) — or when it ends in a sink call another warned hold is long by too,
 * at least as often — one that repeats under its hold is not covered by a hold reaching it once (TM's
 * `FolderWatcher.updateInternal` walk against `rename`'s one stat) — by a hold of the same lock, in the same function, or one
 * whose function the call's way passes (TM's `RemoteFileSystemBase.renameCloudFolderBlocked` over the loop
 * `CloudDatabase.moveCloudFolderSubItemsAction2` runs under its own lock); another lock's hold across the same work elsewhere
 * is a stall of its own. Positive: a lock long by a hand-off, an unresolved call, a release in another function or a
 * hold with no finding is not covered, nor is a hold long by what no call of it names. Holds covering each other round a
 * cycle keep the first by place and fold the rest onto it. Two holds sharing one finding are one warned hold, which never
 * covers itself; an info finding a hold around it turned counts as reported only while the warning it was turned onto does.
 */
@:nullSafety(Strict)
final class RootCauseFold {

	/** How many holds a folded finding names before it counts the rest. */
	private static inline final NAMED_CAP: Int = 3;

	/** The longest way from a hold to its work any warned hold is ranked by before `fold` measures it. */
	private static inline final MAX_DEPTH: Int = 1 << 30;

	/** The holds making each lock long, by index into `_holds`. */
	private final _makers: Map<String, Array<Int>> = [];

	/** For each hold of `_holds`, the index of the warned hold its finding is (`fold`'s `warned`), or -1 for none. */
	private final _warnedAt: Array<Int> = [];

	/** For each warned hold of `fold`, in place order, the fewest calls from the hold to a call it is long by. */
	private final _depth: Array<Int> = [];

	/** The locks long by a release in a function other than the take's (`LockSites.crossing`): no hold names why. */
	private final _crossing: Array<String>;

	/**
	 * Each finding a hold around it turned info (`ThreadSafety.nestHolds`, `foldEnclosed`) with the warnings it was turned
	 * onto: its work is reported only while one of those is.
	 */
	private final _covers: Array<{ finding: Violation, by: Array<Violation> }>;

	/** The holds `fold` judges, in the order it was handed them. */
	private var _holds: Array<FoldHold> = [];

	/** The warned holds of `fold`, one per finding, in place order. */
	private var _warned: Array<FoldHold> = [];

	public function new(crossing: Array<String>, covers: Array<{ finding: Violation, by: Array<Violation> }>) {
		_crossing = crossing;
		_covers = covers;
	}

	/**
	 * Folds the warnings of `holds` whose every long call another warning covers (see the class doc). Two holds whose
	 * finding is one (the same message at the same call) are one warned hold: a finding never covers itself.
	 */
	public function fold(holds: Array<FoldHold>): Void {
		_holds = holds;
		final warned: Array<FoldHold> = [];
		for (h in holds) {
			final finding: Null<Violation> = h.finding;
			if (finding != null && finding.severity == Severity.Warning && !warned.exists(w -> w.finding == finding)) warned.push(h);
		}
		warned.sort(byPlace);
		_warned = warned;
		for (i => h in holds) {
			_warnedAt.push(h.finding == null ? -1 : findingAt(h.finding));
			if (!h.longMaking) continue;
			final list: Array<Int> = _makers[h.lock] ?? [];
			list.push(i);
			_makers[h.lock] = list;
		}
		final reasons: Array<Array<FoldReason>> = [];
		for (h in warned) {
			_depth.push(MAX_DEPTH);
			reasons.push(reasonsOf(h));
		}
		final doing: Map<String, Array<SiteDoer>> = doers(reasons);
		// a hold long by work no other warned hold does too is kept
		final state: Array<FoldState> = [
			for (i => r in reasons) r.length == 0 || r.exists(x -> uncoverable(x, i, doing)) ? Kept : Open
		];
		// what is left covers itself round a cycle: the one nearest its work stays, then the first by place, the rest fold onto it
		while (settle(reasons, doing, state)) {
			var pick: Int = -1;
			for (i in 0...warned.length) if (state[i] == Open && (pick < 0 || _depth[i] < _depth[pick])) pick = i;
			state[pick] = Kept;
		}
		for (i => h in warned) if (state[i] == Folded) turn(h, reasons[i], i, doing);
	}

	/** The index into `_warned` of the warned hold whose finding is `finding`; -1 for none. */
	private function findingAt(finding: Violation): Int {
		for (i => w in _warned) if (w.finding == finding) return i;
		return -1;
	}

	/** Folds every open hold whose reasons all point at kept or folded warnings, to a fixed point; whether any is still open. */
	private function settle(reasons: Array<Array<FoldReason>>, doing: Map<String, Array<SiteDoer>>, state: Array<FoldState>): Bool {
		var moved: Bool = true;
		while (moved) {
			moved = false;
			for (i in 0..._warned.length) if (state[i] == Open && reasons[i].foreach(r -> settled(r, i, doing, state))) {
				state[i] = Folded;
				moved = true;
			}
		}
		return state.contains(Open);
	}

	/**
	 * Why each long call of the warned hold `h` is long, plus `Uncovered` for a hold long by what no call of it names —
	 * whose calls still count as work it does (`Site`).
	 */
	private function reasonsOf(h: FoldHold): Array<FoldReason> {
		final taint: Null<LockTaint> = h.taint;
		if (taint == null) return [Uncovered];
		final out: Array<FoldReason> = h.opaque ? [Uncovered] : [];
		for (c in h.calls) {
			final trail: Null<BlockingTrail> = taint.blockingTrail(h.hold, c, h.held);
			final at: Int = _depth.length - 1;
			if (trail != null && trail.path.length < _depth[at]) _depth[at] = trail.path.length;
			final reason: FoldReason = reasonOf(h, taint, trail);
			if (!out.exists(r -> same(r, reason))) out.push(reason);
		}
		return out;
	}

	/**
	 * The reason the call ending in `trail` of the hold `h` is long under `taint`: a wait for another lock whose long-making
	 * holds are known, or the sink call at its end — work another hold may do too, repeated under the hold or not.
	 */
	private function reasonOf(h: FoldHold, taint: LockTaint, trail: Null<BlockingTrail>): FoldReason {
		if (trail == null) return Uncovered;
		final via: Null<String> = trail.via;
		if (via != null) return via == h.lock || _crossing.contains(via) || !_makers.exists(via) ? Uncovered : Waits(via);
		return Site(MainSinkReport.siteKey(trail.end), taint.repeatsAlong(h.hold, trail), taint.mayRepeatAlong(h.hold, trail), trail.path);
	}

	/**
	 * Whether `reason` of the warned hold at `i` points at warnings already kept or folded (`state`): for a wait, every
	 * hold making the lock long but the hold's own finding; for a sink call, another warned hold long by the same call as
	 * often (`doing`).
	 */
	private function settled(reason: FoldReason, i: Int, doing: Map<String, Array<SiteDoer>>, state: Array<FoldState>): Bool {
		return switch reason {
			case Site(key, _, mayRepeat, way): (doing[key] ?? []).exists(d -> covers(d, i, mayRepeat, way) && state[d.at] != Open);
			case Uncovered: false;
			case Waits(lock): (_makers[lock] ?? []).foreach(m -> _warnedAt[m] != i && reportedFor(m, state));
		};
	}

	/**
	 * Whether the hold at `m` of `_holds` making a lock long has its long work reported by a warning: its own, kept or
	 * folded (`state`), or — for its info finding — a finding (a) warning, or a hold around it whose report does
	 * (`coverReported`).
	 */
	private function reportedFor(m: Int, state: Array<FoldState>): Bool {
		final at: Int = _warnedAt[m];
		if (at >= 0) return state[at] != Open;
		final maker: FoldHold = _holds[m];
		final finding: Null<Violation> = maker.finding;
		if (finding == null || finding.severity != Severity.Info) return false;
		return maker.elsewhere || maker.madeWarning && coverReported(finding, state, []);
	}

	/**
	 * Whether a warning reports the work of `finding`, turned info by a hold around it: one of the warnings it was turned
	 * onto (`_covers`) is kept or folded (`state`), or was itself turned onto one that is.
	 */
	private function coverReported(finding: Violation, state: Array<FoldState>, seen: Array<Violation>): Bool {
		if (seen.contains(finding)) return false;
		seen.push(finding);
		final by: Array<Violation> = _covers.find(c -> c.finding == finding)?.by ?? [];
		return by.exists(c -> {
			final at: Int = findingAt(c);
			at >= 0 ? state[at] != Open : c.severity == Severity.Info && coverReported(c, state, seen);
		});
	}

	/** Turns the warning of `h` (at `i` of `_warned`) info, naming the warnings its `reasons` point at. */
	private function turn(h: FoldHold, reasons: Array<FoldReason>, i: Int, doing: Map<String, Array<SiteDoer>>): Void {
		final finding: Null<Violation> = h.finding;
		if (finding == null) return;
		final parts: Array<String> = [];
		for (r in reasons) switch r {
			case Waits(lock):
				parts.push('waiting for $lock, held long by ${named([for (m in _makers[lock] ?? []) memberOf(_holds[m])])}');
			case Site(key, _, mayRepeat, way):
				parts.push('work ${named([
for (d in doing[key] ?? []) if (covers(d, i, mayRepeat, way)) memberOf(_warned[d.at])
])} also holds a lock across');
			case Uncovered:
		}
		finding.severity = Severity.Info;
		finding.message += ' — long only through ${parts.join('; ')}, reported there';
	}

	/**
	 * The hold `a` before its finding is made: whether it makes its lock long under `costs`, the costed taint over the
	 * normal paths (`makesLong`) — a hold long only where a `catch` runs is reported as info by its own grade — nothing
	 * judged.
	 */
	public static function unreported(a: LockAcquire, costs: LockTaint): FoldHold {
		return {
			hold: a,
			lock: a.lock ?? a.pair.lockId,
			longMaking: makesLong(a, costs),
			finding: null,
			calls: [],
			taint: null,
			held: null,
			opaque: false,
			madeWarning: false,
			elsewhere: false
		};
	}

	/**
	 * `fold` with its finding `finding`, graded `graded` under a hold of `held`, its long calls read over the normal paths
	 * (`normal`: a call only a `catch` runs is no reason a warning warns); `handOff`: graded as handing its lock off.
	 */
	public static function judgedAs(
		fold: FoldHold, finding: Violation, graded: GradedHold, held: Null<String>, normal: LockTaint, handOff: Bool
	): FoldHold {
		return {
			hold: fold.hold,
			lock: fold.lock,
			longMaking: fold.longMaking,
			finding: finding,
			calls: [for (c in normal.blockingCalls(fold.hold, held)) c.edge],
			taint: normal,
			held: held,
			opaque: handOff || graded.taint.blindLong(fold.hold),
			madeWarning: !graded.info,
			elsewhere: graded.elsewhere == true
		};
	}

	/**
	 * Whether the warned hold `d` makes a sink call another one (at `i`) is long by, as often
	 * — repeating along its trail where the other's may (`repeated`) —: a hold reaching it once
	 * reports no stall of one repeating it under its own lock (TM's `FolderWatcher.rename`'s one stat against
	 * `updateInternal`'s walk over the whole tree).
	 */
	private function covers(d: SiteDoer, i: Int, repeated: Bool, way: Array<String>): Bool {
		final by: FoldHold = _warned[d.at];
		final own: FoldHold = _warned[i];
		return d.at != i && (d.repeated || !repeated)
			&& (by.lock == own.lock || by.hold.edge.from == own.hold.edge.from || way.contains(by.hold.edge.from));
	}

	/**
	 * Whether the hold `a` is a reason its lock is long under the costed `costs`, as the solve that made it long reads it
	 * (`ThreadSafety.solveLongLocks`): it outlives its function, spans an unresolved call long on its own, or — taken
	 * where another thread may contend — spans a call that blocks.
	 */
	private static function makesLong(a: LockAcquire, costs: LockTaint): Bool {
		if (a.lock == null) return false;
		if (LongLockExplain.leaks(a) || costs.blindLong(a)) return true;
		final held: Null<String> = costs.reentrantHeld(a);
		return !a.uncontended && a.window.exists(e -> costs.blockingPath(a, e, held) != null);
	}

	/** By `MainSinkReport.siteKey`, the warned holds (by index into `reasons`) long by each sink call, repeated or not. */
	private static function doers(reasons: Array<Array<FoldReason>>): Map<String, Array<SiteDoer>> {
		final doing: Map<String, Array<SiteDoer>> = [];
		for (i => r in reasons) for (reason in r) switch reason {
			case Site(key, repeated, _, _):
				doing[key] = (doing[key] ?? []).concat([{ at: i, repeated: repeated }]);
			case _:
		}
		return doing;
	}

	/**
	 * Whether `reason` of the warned hold at `i` can never be covered: long by what no call names, or by a sink call no
	 * other warned hold makes at least as often (`covers`).
	 */
	private function uncoverable(reason: FoldReason, i: Int, doing: Map<String, Array<SiteDoer>>): Bool {
		return switch reason {
			case Uncovered: true;
			case Site(key, _, mayRepeat, way): !(doing[key] ?? []).exists(d -> covers(d, i, mayRepeat, way));
			case Waits(_): false;
		};
	}

	private static function memberOf(m: FoldHold): String {
		return m.finding?.data?.member ?? m.hold.edge.from;
	}

	/** By member, file and offset of the hold's finding. */
	private static function byPlace(a: FoldHold, b: FoldHold): Int {
		final x: String = '${memberOf(a)}\n${a.finding?.file}';
		final y: String = '${memberOf(b)}\n${b.finding?.file}';
		return x != y ? Reflect.compare(x, y) : (a.finding?.span?.from ?? 0) - (b.finding?.span?.from ?? 0);
	}

	private static function named(all: Array<String>): String {
		final members: Array<String> = [];
		for (m in all) if (!members.contains(m)) members.push(m);
		final more: Int = members.length - NAMED_CAP;
		return members.slice(0, NAMED_CAP).join(', ') + (more > 0 ? ' (+$more more)' : '');
	}

	private static function same(a: FoldReason, b: FoldReason): Bool {
		return switch [a, b] {
			case [Waits(x), Waits(y)]: x == y;
			case [Site(x, r, m, _), Site(y, s, n, _)]:
				x == y && r == s && m == n;
			case [Uncovered, Uncovered]: true;
			case _: false;
		};
	}

}
