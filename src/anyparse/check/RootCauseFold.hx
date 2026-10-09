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
	Site(key: String);
	Uncovered;
}

/**
 * One warning per root cause across holds: a hold finding (b) warning whose every long call is long only through what
 * another warned hold already reports turns info, naming those holds. A call counts as covered when it waits for a lock
 * every hold making that lock long has its long work reported — its own warning, kept or folded, or the warning its info
 * finding names (TM's tree lock, held long by `FolderWatcher.updateInternal`, which `StandardFileSystem.saveXML` waits
 * for under the mutation lock) — or when it ends in a sink call another warned hold is long by too (TM's
 * `RemoteFileSystemBase.renameCloudFolderBlocked` over the loop `CloudDatabase.moveCloudFolderSubItemsAction2` runs
 * under its own lock). Positive: a lock long by a hand-off, an unresolved call, a release in another function or a
 * hold with no finding is not covered, nor is a hold long by what no call of it names. Holds covering each other round
 * a cycle keep the first by place and fold the rest onto it.
 */
@:nullSafety(Strict)
final class RootCauseFold {

	/** The holds making each lock long. */
	private final _makers: Map<String, Array<FoldHold>> = [];

	/** The locks long by a release in a function other than the take's (`LockSites.crossing`): no hold names why. */
	private final _crossing: Array<String>;

	/** How many holds a folded finding names before it counts the rest. */
	private static inline final NAMED_CAP: Int = 3;

	/** The longest way from a hold to its work any warned hold is ranked by before `fold` measures it. */
	private static inline final MAX_DEPTH: Int = 1 << 30;

	/** For each warned hold of `fold`, in place order, the fewest calls from the hold to a call it is long by. */
	private final _depth: Array<Int> = [];

	public function new(crossing: Array<String>) {
		_crossing = crossing;
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

	/** Folds the warnings of `holds` whose every long call another warning covers (see the class doc). */
	public function fold(holds: Array<FoldHold>): Void {
		for (h in holds) if (h.longMaking) {
			final list: Array<FoldHold> = _makers[h.lock] ?? [];
			list.push(h);
			_makers[h.lock] = list;
		}
		final warned: Array<FoldHold> = [
			for (h in holds) if (h.finding != null && h.finding.severity == Severity.Warning) h
		];
		warned.sort(byPlace);
		final reasons: Array<Array<FoldReason>> = [];
		for (h in warned) {
			_depth.push(MAX_DEPTH);
			reasons.push(reasonsOf(h));
		}
		final doing: Map<String, Array<Int>> = doers(reasons);
		// 0 open, 1 kept, 2 folded; a hold long by work no other warned hold does too is kept
		final state: Array<Int> = [for (r in reasons) r.length == 0 || r.exists(x -> uncoverable(x, doing)) ? 1 : 0];
		// what is left covers itself round a cycle: the one nearest its work stays, then the first by place, the rest fold onto it
		while (settle(warned, reasons, doing, state)) {
			var pick: Int = -1;
			for (i in 0...warned.length) if (state[i] == 0 && (pick < 0 || _depth[i] < _depth[pick])) pick = i;
			state[pick] = 1;
		}
		for (i => h in warned) if (state[i] == 2) turn(h, reasons[i], i, warned, doing);

	}

	/** By `MainSinkReport.siteKey`, the warned holds (by index into `reasons`) long by each sink call. */
	private static function doers(reasons: Array<Array<FoldReason>>): Map<String, Array<Int>> {
		final doing: Map<String, Array<Int>> = [];
		for (i => r in reasons) for (reason in r) switch reason {
			case Site(key):
				doing[key] = (doing[key] ?? []).concat([i]);
			case _:
		}
		return doing;
	}

	/** Whether `reason` can never be covered: long by what no call names, or by a sink call no other warned hold makes. */
	private static function uncoverable(reason: FoldReason, doing: Map<String, Array<Int>>): Bool {
		return switch reason {
			case Uncovered: true;
			case Site(key): (doing[key] ?? []).length < 2;
			case Waits(_): false;
		};
	}

	/** Folds every open hold whose reasons all point at kept or folded warnings, to a fixed point; whether any is still open. */
	private function settle(
		warned: Array<FoldHold>, reasons: Array<Array<FoldReason>>, doing: Map<String, Array<Int>>, state: Array<Int>
	): Bool {
		var moved: Bool = true;
		while (moved) {
			moved = false;
			for (i => h in warned) if (state[i] == 0 && reasons[i].foreach(r -> settled(r, i, warned, doing, state))) {
				state[i] = 2;
				moved = true;
			}
		}
		return state.contains(0);
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
			final reason: FoldReason = reasonOf(h, trail);
			if (!out.exists(r -> same(r, reason))) out.push(reason);
		}
		return out;
	}

	/**
	 * The reason the call ending in `trail` of the hold `h` is long: a wait for another lock whose long-making holds are
	 * known, or the sink call at its end — work another hold may do too.
	 */
	private function reasonOf(h: FoldHold, trail: Null<BlockingTrail>): FoldReason {
		if (trail == null) return Uncovered;
		final via: Null<String> = trail.via;
		if (via != null) return via == h.lock || _crossing.contains(via) || !_makers.exists(via) ? Uncovered : Waits(via);
		return Site(MainSinkReport.siteKey(trail.end));
	}

	/**
	 * Whether `reason` of the warned hold at `i` points at warnings already kept or folded (`state`): for a wait, every
	 * hold making the lock long; for a sink call, another warned hold long by the same call (`doing`).
	 */
	private function settled(
		reason: FoldReason, i: Int, warned: Array<FoldHold>, doing: Map<String, Array<Int>>, state: Array<Int>
	): Bool {
		final h: FoldHold = warned[i];
		return switch reason {
			case Site(key): (doing[key] ?? []).exists(j -> j != i && state[j] != 0);
			case Uncovered: false;
			case Waits(lock): (_makers[lock] ?? []).foreach(m -> m != h && reportedFor(m, warned.indexOf(m), state));
		};
	}

	/**
	 * Whether the hold `m` making a lock long has its long work reported by a warning: its own, kept or folded (`state`
	 * at `at` in the warned holds), or the one its info finding names — turned by a hold around it, or a main-only hold's
	 * own work a finding (a) warns of.
	 */
	private static function reportedFor(m: FoldHold, at: Int, state: Array<Int>): Bool {
		if (at >= 0) return state[at] != 0;
		final finding: Null<Violation> = m.finding;
		return finding != null && finding.severity == Severity.Info && (m.madeWarning || m.elsewhere);
	}

	/** Turns the warning of `h` (at `i` of `warned`) info, naming the warnings its `reasons` point at. */
	private function turn(
		h: FoldHold, reasons: Array<FoldReason>, i: Int, warned: Array<FoldHold>, doing: Map<String, Array<Int>>
	): Void {
		final finding: Null<Violation> = h.finding;
		if (finding == null) return;
		final parts: Array<String> = [];
		for (r in reasons) switch r {
			case Waits(lock):
				parts.push('waiting for $lock, held long by ${named([for (m in _makers[lock] ?? []) memberOf(m)])}');
			case Site(key):
				parts.push('work ${named([for (j in doing[key] ?? []) if (j != i) memberOf(warned[j])])} also holds a lock across');
			case Uncovered:
		}
		finding.severity = Severity.Info;
		finding.message += ' — long only through ${parts.join('; ')}, reported there';
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
			case [Site(x), Site(y)]: x == y;
			case [Uncovered, Uncovered]: true;
			case _: false;
		};
	}

}
