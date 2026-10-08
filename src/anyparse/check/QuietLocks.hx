package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockTaint.ChainLists;
import anyparse.query.CallGraph;

using Lambda;

/**
 * The takes that never wait, whatever the lock is: every take of a lock some member names made through a `sharedLocks`
 * member (a shared take waits only for an exclusive one, and there is none), and a take in its owner's constructor before
 * the object can reach another thread (`LockAcquire.uncontended`).
 */
@:nullSafety(Strict)
final class QuietLocks {

	/** Each lock -> whether every take of it is a shared one. */
	private final _sharedOnly: Map<String, Bool> = [];

	/** The takes in their owner's constructor, by `<file>:<offset>:<target>`; built on the first question. */
	private var _uncontended: Null<Map<String, Bool>> = null;

	private final _sites: LockSites;
	private final _listsOf: (String) -> ChainLists;

	public function new(sites: LockSites, listsOf: (String) -> ChainLists) {
		_sites = sites;
		_listsOf = listsOf;
	}

	/** Whether the lock take `edge` never waits: its lock is taken only shared (`sharedOnly`), or it is a constructor's take before publication. */
	public function never(edge: CallEdge): Bool {
		final lock: String = _sites.lockOf(edge) ?? '';
		return lock != '' && sharedOnly(lock) || uncontended(edge);
	}

	/**
	 * Whether every take of the named lock `lock` — every hold of it, a helper's included — is made through a member its
	 * site's chain lists under `sharedLocks`: shared takes never wait for one another.
	 */
	public function sharedOnly(lock: String): Bool {
		final known: Null<Bool> = _sharedOnly[lock];
		if (known != null) return known;
		final takes: Array<LockAcquire> = [for (a in _sites.acquires.concat(_sites.helperHolds)) if (a.lock == lock) a];
		final answer: Bool = takes.length > 0 && takes.foreach(a -> _listsOf(a.edge.file).sharedIds.contains(a.pair.lockId));
		_sharedOnly[lock] = answer;
		return answer;
	}

	/** Whether the take `edge` is a hold in its owner's constructor on an instance lock before the object escapes. */
	private function uncontended(edge: CallEdge): Bool {
		var known: Null<Map<String, Bool>> = _uncontended;
		if (known == null) {
			final built: Map<String, Bool> = [];
			for (a in _sites.acquires) if (a.uncontended) built[keyOf(a.edge)] = true;
			_uncontended = built;
			known = built;
		}
		return known.exists(keyOf(edge));
	}

	private static inline function keyOf(edge: CallEdge): String {
		return '${edge.file}:${edge.span?.from ?? -1}:${edge.to}';
	}

}
