package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.LockSites.LockAcquire;
import anyparse.check.ThreadSafety.CostNote;
import anyparse.check.ThreadSafety.FindingFamily;
import anyparse.query.CallGraph;

using Lambda;

/** The calls a hold finding names, the taint that found them, and what its message adds (`HoldGrade.grade`). */
typedef GradedHold = {
	final calls: Array<{ edge: CallEdge, path: Array<String> }>;
	final taint: LockTaint;
	final note: String;

	/** Whether the finding is info: every call brief, or long only where a `catch` runs. */
	final info: Bool;

	/** Whether it is info because a finding (a) warning names its every long call: a main-only hold's own work. */
	final ?elsewhere: Bool;
}

/** One hold finding (b) judges: its lock, whether it makes that lock long, and, once warned, what it was judged by. */
typedef FoldHold = {
	final hold: LockAcquire;

	/** The lock object, or the pair's take member for a lock no member names. */
	final lock: String;

	/** Whether the hold is a reason its lock is long (`ThreadSafety.solveLongLocks`). */
	final longMaking: Bool;

	/** Its finding (b), when one was made, whatever its severity. */
	final finding: Null<Violation>;

	/** The long calls the finding names, the taint that found them, and the lock re-held there; empty for no finding. */
	final calls: Array<CallEdge>;

	final taint: Null<LockTaint>;
	final held: Null<String>;

	/** Whether the hold is long by something no call of it names: handed off past its function, or an unresolved call. */
	final opaque: Bool;

	/**
	 * Whether its finding, when info, names where its long calls are reported instead: made a warning and turned by a
	 * hold around it (`ThreadSafety.nestHolds`, `foldEnclosed`), or a main-only hold whose work a finding (a) warns of.
	 */
	final madeWarning: Bool;

	final elsewhere: Bool;
}

/**
 * The taints a hold is judged by: every blocking call (`plain`), the long ones (`long` — the holder's own long work for
 * a hold only the main thread runs), the long ones over the normal paths (`normal`), and where those part (`errors`).
 */
typedef HoldJudges = {
	final plain: LockTaint;
	final long: LockTaint;
	final normal: LockTaint;
	final errors: ErrorPaths;

	/** By `MainSinkReport.siteKey`, the finding (a) warning that reports each main-thread sink call. */
	final reported: Map<String, Violation>;
}

/**
 * How finding (b) grades one hold: a hold its function hands off is long whatever its window spans; any other names the
 * calls that block long — info when they block long only where a `catch` runs — or, unless only the main thread runs
 * it, every call that blocks at all, graded short.
 */
@:nullSafety(Strict)
final class HoldGrade {

	/**
	 * The calls a finding (b) names for the hold `a` of `sites` under a hold of `held`, judged by `judges`, with the taint
	 * that found them and what the message adds; null when none. `mainOnly`: only the main thread runs the hold.
	 */
	public static function grade(
		sites: LockSites, a: LockAcquire, held: Null<String>, judges: HoldJudges, mainOnly: Bool
	): Null<GradedHold> {
		return !mainOnly && handsOff(sites, a) ? handOff(a, held, judges.plain) : byCost(a, held, judges, mainOnly);
	}

	/**
	 * The holds findings (b) judge: every one of `acquires` but a multi-lock helper's own takes, which are its callers'
	 * holds (`helperHolds`), judged where the helper is called.
	 */
	public static function judged(sites: LockSites, acquires: Array<LockAcquire>, helperHolds: Array<LockAcquire>): Array<LockAcquire> {
		return [for (a in acquires) if (!sites.helpers.contains(a.edge.from)) a].concat(helperHolds);
	}

	/**
	 * Whether the hold `a` HANDS its lock OFF: it outlives its function on some path, and nothing of the function gives
	 * the lock back — no give of it there, no call in its window of a function that releases it without taking it — so
	 * on every path that takes it, it stays held past the end until another function releases it. Never a lock wrapper's
	 * own take, a multi-lock helper's, an untraced hold or one of a lock no member names — nor a hold whose window spans no
	 * call: a function that only takes the lock hands it to its caller, whose own code runs under it.
	 */
	public static function handsOff(sites: LockSites, a: LockAcquire): Bool {
		final lock: Null<String> = a.lock;
		if (lock == null || !a.leaks || a.delegated || a.untraced || a.inner != null || a.window.length == 0) return false;
		if (sites.helpers.contains(a.edge.from)) return false;
		return !sites.gives.exists(g -> g.edge.from == a.edge.from && g.lock == lock)
			&& !a.window.exists(e -> sites.crossing.exists(c -> c.lock == lock && c.edge.from == e.to));
	}

	/**
	 * The finding (b) of the hold `a` that hands its lock off (`handsOff`): held past its function's end until another
	 * function releases it, it is long whatever its window spans — named by the calls that block at all under `taints`,
	 * or by its take when none does.
	 */
	private static function handOff(a: LockAcquire, held: Null<String>, taints: LockTaint): GradedHold {
		final calls: Array<{ edge: CallEdge, path: Array<String> }> = taints.blockingCalls(a, held);
		return {
			calls: calls.length > 0 ? calls : [{ edge: a.edge, path: [a.edge.to] }],
			taint: taints,
			note: CostNote.HandOff,
			info: false
		};
	}

	/**
	 * The members whose finding (a) warnings report every long call `long` of the main-only hold `a` — the sink call
	 * each one ends in (`LockTaint.blockingTrail`), warned at itself or at the repeating call that owns it, the hold's
	 * own member included (TM's `FileListMoveFiles.moveItems` loop); null otherwise. The main thread's own long work is
	 * finding (a)'s: a hold of it adds no second warning where (a) already names it.
	 */
	private static function reportedElsewhere(
		a: LockAcquire, held: Null<String>, long: Array<{ edge: CallEdge, path: Array<String> }>, judges: HoldJudges
	): Null<String> {
		final members: Array<String> = [];
		for (c in long) {
			final end: Null<CallEdge> = judges.long.blockingTrail(a, c.edge, held)?.end;
			final by: Null<String> = end == null ? null : judges.reported[MainSinkReport.siteKey(end)]?.data?.member;
			if (by == null) return null;
			if (!members.contains(by)) members.push(by);
		}
		return members.length == 0 ? null : members.join(', ');
	}

	/**
	 * The calls that block long under `judges.long` (the holder's own long work, `mainOnly`) — info when none blocks long
	 * under `judges.normal`, over the normal paths, naming the `catch` its first call's way passes (`ErrorPaths`) — or
	 * else, unless only the main thread runs the hold, every call that blocks at all under `judges.plain`, graded short.
	 */
	private static function byCost(a: LockAcquire, held: Null<String>, judges: HoldJudges, mainOnly: Bool): Null<GradedHold> {
		final long: Array<{ edge: CallEdge, path: Array<String> }> = judges.long.blockingCalls(a, held);
		if (long.length > 0) {
			// long only where a `catch` runs: no call of the hold blocks long over the normal paths
			final error: Null<String> = judges.normal.blockingCalls(a, held).length > 0
				? null
				: judges.errors.placeOf(judges.long.blockingTrail(a, long[0].edge, held)?.edges ?? []);
			final note: String = error != null ? ErrorPaths.note(error) : mainOnly ? CostNote.MainOwnWork : '';
			final elsewhere: Null<String> = mainOnly && error == null ? reportedElsewhere(a, held, long, judges) : null;
			return {
				calls: long,
				taint: judges.long,
				note: elsewhere == null ? note : note + ', which finding (a) reports at $elsewhere, so reported as info',
				info: error != null || elsewhere != null,
				elsewhere: error == null && elsewhere != null
			};
		}
		if (mainOnly) return null;
		final brief: Array<{ edge: CallEdge, path: Array<String> }> = judges.plain.blockingCalls(a, held);
		return brief.length == 0 ? null : {
			calls: brief,
			taint: judges.plain,
			note: CostNote.ShortHold,
			info: true
		};
	}

	/** Finding (b) at the call `anchor` of `holder`'s hold of `lock` (`chain[0]`), info when `short`. */
	public static function finding(
		graph: CallGraph, anchor: CallEdge, short: Bool, message: String, lock: String, chain: Array<String>
	): Violation {
		return {
			file: anchor.file,
			span: anchor.span,
			rule: 'thread-safety',
			severity: short ? Severity.Info : Severity.Warning,
			message: message,
			data: {
				family: FindingFamily.LockHeld,
				member: ThreadSafety.memberOf(graph, chain[0]),
				subject: lock,
				chain: chain
			}
		};
	}

	/**
	 * The locks the main thread takes somewhere, of `acquires`: a lock only ever taken shared stalls no one; one no member
	 * names is told apart by its pair's take member alone.
	 */
	public static function mainTaken(acquires: Array<LockAcquire>, states: ThreadStates, taints: LockTaint): Array<String> {
		return [
			for (a in acquires) {
				final lock: String = a.lock ?? a.pair.lockId;
				if (states.edgeContext(a.edge) & ThreadSafety.CTX_MAIN != 0 && !taints.quiet.sharedOnly(lock)) lock;
			}
		];
	}

}
