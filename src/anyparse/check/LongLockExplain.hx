package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.query.CallGraph;
import anyparse.runtime.Span;

using Lambda;

/**
 * One reason `thread-safety` holds a lock LONG, at one site. `kind` is one of the `LongLockExplain` kinds; `holder` is
 * the function the site sits in; a `spans-blocking` reason also names the call the hold spans (`call`) and the path
 * from the holder to the call that blocks (`chain`, empty for every other kind).
 */
typedef LongLockReason = {
	final kind: String;
	final file: String;
	final span: Null<Span>;
	final holder: String;
	final call: Null<String>;
	final chain: Array<String>;
}

/**
 * One long lock and every reason found for it. `aside` answers what the lock is long by once its OWN reasons that need
 * no blocking call (`crossing`, `leak`, `blind`) are set aside: the `spans-blocking` reason a solve without them finds,
 * none when the lock would then be short — and it is null for a lock that already spans a blocking call, or that no
 * member names.
 */
typedef LongLock = {
	final lock: String;
	final reasons: Array<LongLockReason>;
	final aside: Null<Array<LongLockReason>>;
}

/** A lock the solve found long by a hold spanning a blocking call, with that reason. */
typedef GrownLock = {
	final lock: String;
	final reason: LongLockReason;
}

/** A take of a lock on the main thread: the lock, where, and the function taking it. */
typedef LockTakeSite = {
	final lock: String;
	final file: String;
	final span: Null<Span>;
	final holder: String;
}

/** What `--explain-long` reports: every long lock with its reasons, and every main-thread take of a lock that is NOT long. */
typedef LongLockReport = {
	final long: Array<LongLock>;
	final mainShort: Array<LockTakeSite>;
}

/**
 * Why `thread-safety` deems each lock long — the evidence `ThreadSafety.solveLongLocks` acts on, kept as data. A lock
 * is long on its own when some function releases it without taking it (`crossing`), a hold of it may outlive its
 * function (`leak`), or spans a call the graph resolves to nothing (`blind`); it grows long when a hold of it spans a
 * call that blocks (`spans-blocking`), a long lock's take included. A lock no sealed member names is always long
 * (`unnamed`). Reading the evidence changes no finding.
 */
@:nullSafety(Strict)
final class LongLockExplain {

	public static inline final KIND_CROSSING: String = 'crossing';
	public static inline final KIND_LEAK: String = 'leak';
	public static inline final KIND_BLIND: String = 'blind';
	public static inline final KIND_UNNAMED: String = 'unnamed';
	public static inline final KIND_SPANS_BLOCKING: String = 'spans-blocking';

	/**
	 * Whether the hold `a` makes its lock long with no blocking call in sight by outliving its function: whatever holds it
	 * then may hold it any time at all. A wrapper's own take leaks by design: whether it lasts is decided at each call of
	 * the wrapper, an acquire itself.
	 */
	public static inline function leaks(a: LockAcquire): Bool {
		return a.leaks && !a.delegated;
	}

	/** Whether the hold `a` makes its lock long by spanning a call to nothing the graph knows, which may run anything. */
	public static inline function blind(a: LockAcquire): Bool {
		return a.blind && !a.uncontended;
	}

	/** The `spans-blocking` reason of the hold `a`: its call `edge` reaches a blocking call by `path` (`LockTaint.blockingPath`). */
	public static function spansBlocking(a: LockAcquire, edge: CallEdge, path: Array<String>): LongLockReason {
		return {
			kind: KIND_SPANS_BLOCKING,
			file: edge.file,
			span: edge.span,
			holder: a.edge.from,
			call: edge.to,
			chain: [a.edge.from].concat(path)
		};
	}

	/**
	 * The report over the holds `acquires` of `sites`: each lock of `long` with its reasons — the release sites making it
	 * crossing, the holds `leaks` and `blind` find, the `grown` reasons the solve found
	 * — in `long`'s order, then each unnamed lock; `aside` solves a lock's evidence without its own reasons. `mainTakes`
	 * are the holds a main-thread state runs the take of.
	 */
	public static function report(
		sites: LockSites, acquires: Array<LockAcquire>, long: Array<String>, grown: Array<GrownLock>, mainTakes: Array<LockAcquire>,
		aside: (String) -> Array<LongLockReason>
	): LongLockReport {
		final byLock: Map<String, Array<LongLockReason>> = [];
		final order: Array<String> = long.copy();
		function add(lock: String, reason: LongLockReason): Void {
			final known: Array<LongLockReason> = byLock[lock] ?? [];
			if (!known.exists(r -> r.kind == reason.kind && r.file == reason.file && r.span?.from == reason.span?.from)) known.push(reason);
			byLock[lock] = known;
			if (!order.contains(lock)) order.push(lock);
		}
		for (c in sites.crossing) add(c.lock, siteReason(KIND_CROSSING, c.edge));
		for (a in acquires) {
			final lock: Null<String> = a.lock;
			if (lock == null) {
				add(a.pair.lockId, siteReason(KIND_UNNAMED, a.edge));
				continue;
			}
			if (leaks(a)) add(lock, siteReason(KIND_LEAK, a.edge));
			if (blind(a)) add(lock, siteReason(KIND_BLIND, a.edge));
		}
		for (g in grown) add(g.lock, g.reason);
		final out: Array<LongLock> = [
			for (lock in order) {
				final reasons: Array<LongLockReason> = byLock[lock] ?? [];
				final named: Bool = long.contains(lock);
				final spans: Bool = reasons.exists(r -> r.kind == KIND_SPANS_BLOCKING);
				{ lock: lock, reasons: reasons, aside: named && !spans ? aside(lock) : null };
			}
		];
		return { long: out, mainShort: shortTakes(mainTakes, long) };
	}

	/** Each take of `takes` of a named lock `long` leaves out, once per site. */
	private static function shortTakes(takes: Array<LockAcquire>, long: Array<String>): Array<LockTakeSite> {
		final out: Array<LockTakeSite> = [];
		for (a in takes) {
			final named: Null<String> = a.lock;
			if (named == null || long.contains(named) || out.exists(t -> t.file == a.edge.file && t.span?.from == a.edge.span?.from))
				continue;
			final lock: String = named;
			out.push({
				lock: lock,
				file: a.edge.file,
				span: a.edge.span,
				holder: a.edge.from
			});
		}
		return out;
	}

	/** A reason of `kind` sitting at the call `edge`, in the function making it. */
	private static function siteReason(kind: String, edge: CallEdge): LongLockReason {
		return {
			kind: kind,
			file: edge.file,
			span: edge.span,
			holder: edge.from,
			call: null,
			chain: []
		};
	}

}
