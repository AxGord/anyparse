package anyparse.check;

import anyparse.check.LockSites.BlindCall;
import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockTaint.BlockingTrail;
import anyparse.query.CallGraph;
import anyparse.runtime.Span;

using Lambda;

/** Why `thread-safety` deems a lock long (`LongLockExplain`): a closed set. */
enum abstract LongLockKind(String) to String {

	/** A function releases the lock without taking it: the hold began in another function. */
	final Crossing = 'crossing';

	/** A hold may outlive its function. */
	final Leak = 'leak';

	/** A hold spans calls the graph resolves to nothing (`LongLockReason.unresolved`), which may run anything. */
	final Blind = 'blind';

	/** A hold the control-flow walk could not trace at all: taken to leak and to be blind. */
	final Untraced = 'untraced';

	/** No sealed member names the lock: an unknown lock is always long. */
	final Unnamed = 'unnamed';

	/** A hold spans a call that blocks: one reaching a sink, or taking a long lock (`LongLockReason.via`). */
	final SpansBlocking = 'spans-blocking';

}

/**
 * One reason `thread-safety` holds a lock long, at one site: its `kind`, the site and the function it sits in
 * (`holder`). A `spans-blocking` reason also names the call the hold spans (`call`, one target of it), the path from the
 * holder to a call that blocks (`chain`) and, when that call blocks by taking a lock, the lock it waits for (`via`); a
 * `blind` one the calls the graph resolves to nothing (`unresolved`). `chain` and `via` are ONE witness the walk found,
 * not the only way the call blocks: compare two reports by site and call, never by `via`.
 */
typedef LongLockReason = {
	final kind: LongLockKind;
	final file: String;
	final span: Null<Span>;
	final holder: String;
	final call: Null<String>;
	final chain: Array<String>;
	final via: Null<String>;
	final unresolved: Array<BlindCall>;
}

/**
 * One long lock and every reason found for it. `aside` answers, for a lock long on reasons of its own (`crossing`,
 * `leak`, `blind`, `untraced`), what it is long by once those are set aside: every `spans-blocking` reason of its holds
 * in a solve without them, none when it would then be short. Null for a lock long only by spanning blocking calls, and
 * for an unnamed one. A hold waiting for the lock ITSELF (`via` the lock) blocks only once the lock is long already, so
 * such a reason is circular: left out of `reasons` and `aside` alike, and counted in `circular`.
 */
typedef LongLock = {
	final lock: String;
	final reasons: Array<LongLockReason>;
	final circular: Int;
	final aside: Null<Array<LongLockReason>>;
}

/** A hold whose take a main-thread state runs — `quiet` when only through a `quietRoots` function. */
typedef MainTake = {
	final take: LockAcquire;
	final quiet: Bool;
}

/** A take of a lock on the main thread: the lock, where, the function taking it, and whether only a quiet path takes it. */
typedef LockTakeSite = {
	final lock: String;
	final file: String;
	final span: Null<Span>;
	final holder: String;
	final quiet: Bool;
}

/** What `--explain-long` reports: every long lock with its reasons, and every main-thread take of a lock that is not long. */
typedef LongLockReport = {
	final long: Array<LongLock>;
	final mainShort: Array<LockTakeSite>;
}

/**
 * Why `thread-safety` deems each lock long — the evidence `ThreadSafety.solveLongLocks` acts on, read back after it
 * converged: every reason at every site, never only the first that tipped the solve. A lock is long on its own when a
 * function releases it without taking it, a hold of it may outlive its function, or spans a call the graph cannot
 * resolve; it is long when a hold of it spans a call that blocks — a sink, or a long lock's take; an unnamed lock always
 * is. Reading the evidence changes no finding.
 */
@:nullSafety(Strict)
final class LongLockExplain {

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

	/**
	 * The report over the holds `acquires` of `sites`, against the converged `long` locks and their `taints`: each long
	 * lock, in `long`'s order, with its crossing releases, its leaking, blind and untraced holds, and every call a hold of
	 * it spans that blocks; then each unnamed lock. `aside` solves a lock's counterfactual and hands back its taint;
	 * `mainTakes` are the holds a main-thread state takes.
	 */
	public static function report(
		sites: LockSites, acquires: Array<LockAcquire>, long: Array<String>, taints: LockTaint, mainTakes: Array<MainTake>,
		aside: (String) -> LockTaint
	): LongLockReport {
		final byLock: Map<String, Array<LongLockReason>> = [];
		final circular: Map<String, Int> = [];
		final order: Array<String> = long.copy();
		function add(lock: String, reason: LongLockReason): Void {
			byLock[lock] = distinct((byLock[lock] ?? []).concat([reason]));
			if (!order.contains(lock)) order.push(lock);
		}
		for (c in sites.crossing) add(c.lock, siteReason(Crossing, c.edge, []));
		for (a in acquires) {
			final lock: Null<String> = a.lock;
			if (lock == null)
				add(a.pair.lockId, siteReason(Unnamed, a.edge, []))
			else if (a.untraced && (leaks(a) || blind(a)))
				add(lock, siteReason(Untraced, a.edge, []))
			else
				for (reason in ownReasons(a)) add(lock, reason);
		}
		for (lock in long) {
			final spans: Array<LongLockReason> = spansBlocking(acquires, lock, taints);
			for (reason in spans) if (reason.via != lock) add(lock, reason);
			circular[lock] = distinct(spans.filter(r -> r.via == lock)).length;
		}
		final out: Array<LongLock> = [
			for (lock in order) {
				final reasons: Array<LongLockReason> = byLock[lock] ?? [];
				final own: Bool = long.contains(lock) && reasons.exists(r -> r.kind != SpansBlocking);
				{
					lock: lock,
					reasons: reasons,
					circular: circular[lock] ?? 0,
					aside: own ? distinct(spansBlocking(acquires, lock, aside(lock)).filter(r -> r.via != lock)) : null
				};
			}
		];
		return { long: out, mainShort: shortTakes(mainTakes, long) };
	}

	/**
	 * `reasons` with each site once: the same kind at the same call site toward the same target (`call`) — a virtual call
	 * dispatching to several targets keeps one reason per target. The one normaliser `reasons` and `aside` both go through.
	 */
	private static function distinct(reasons: Array<LongLockReason>): Array<LongLockReason> {
		final out: Array<LongLockReason> = [];
		for (r in reasons) if (!out.exists(o -> o.kind == r.kind && o.file == r.file && o.span?.from == r.span?.from && o.call == r.call))
			out.push(r);
		return out;
	}

	/** The leak and blind reasons of the traced hold `a`, at its take. */
	private static function ownReasons(a: LockAcquire): Array<LongLockReason> {
		return (leaks(a) ? [siteReason(Leak, a.edge, [])] : []).concat(blind(a) ? [siteReason(Blind, a.edge, a.blindCalls)] : []);
	}

	/**
	 * Every call a hold of `lock` among `acquires` spans that blocks under `taints` (`LockTaint.blockingTrail`): one reason
	 * per call, with its path and the lock it waits for. A hold in the owner's constructor (`LockAcquire.uncontended`)
	 * blocks no one.
	 */
	private static function spansBlocking(acquires: Array<LockAcquire>, lock: String, taints: LockTaint): Array<LongLockReason> {
		final out: Array<LongLockReason> = [];
		for (a in acquires) if (a.lock == lock && !a.uncontended) {
			final held: Null<String> = taints.reentrantHeld(a);
			for (e in a.window) {
				final trail: Null<BlockingTrail> = taints.blockingTrail(a, e, held);
				if (trail != null) out.push({
					kind: SpansBlocking,
					file: e.file,
					span: e.span,
					holder: a.edge.from,
					call: e.to,
					chain: [a.edge.from].concat(trail.path),
					via: trail.via,
					unresolved: []
				});
			}
		}
		return out;
	}

	/** Each take of `takes` of a named lock `long` leaves out, once per site. */
	private static function shortTakes(takes: Array<MainTake>, long: Array<String>): Array<LockTakeSite> {
		final out: Array<LockTakeSite> = [];
		for (t in takes) {
			final a: LockAcquire = t.take;
			final named: Null<String> = a.lock;
			if (named == null || long.contains(named) || out.exists(o -> o.file == a.edge.file && o.span?.from == a.edge.span?.from))
				continue;
			final lock: String = named;
			out.push({
				lock: lock,
				file: a.edge.file,
				span: a.edge.span,
				holder: a.edge.from,
				quiet: t.quiet
			});
		}
		return out;
	}

	/** A reason of `kind` sitting at the call `edge`, in the function making it, with the `unresolved` calls of a blind one. */
	private static function siteReason(kind: LongLockKind, edge: CallEdge, unresolved: Array<BlindCall>): LongLockReason {
		return {
			kind: kind,
			file: edge.file,
			span: edge.span,
			holder: edge.from,
			call: null,
			chain: [],
			via: null,
			unresolved: unresolved
		};
	}

}
