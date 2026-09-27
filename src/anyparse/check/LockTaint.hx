package anyparse.check;

import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockSites.LockPair;
import anyparse.query.CallGraph;

using Lambda;

/**
 * One `apqlint.json` chain's `thread-safety` lists: the three name lists resolved to graph ids, the lock pairs as
 * written (a malformed one is reported) and as resolved.
 */
typedef ChainLists = {

	/** Whether the chain names any `sinks` — a chain that names none is read for the graph and reports nothing. */
	final reports: Bool;

	final sinkIds: Array<String>;
	final spawnIds: Array<String>;
	final marshalIds: Array<String>;
	final quietIds: Array<String>;

	/** The `lockPairs` take members whose lock the thread holding it may take again without waiting. */
	final reentrantIds: Array<String>;
	final lockPairs: Array<String>;
	final pairs: Array<LockPair>;
}

/**
 * Which calls block, and the taint that says how a function reaches one (`hops`: a function's next edge toward a
 * sink), for a hold of each re-entrant lock the holder may take again freely — the plain taint under `null`. The maps
 * are built on demand and dropped by `clear` whenever the long locks grow.
 */
@:nullSafety(Strict)
final class LockTaint {

	public final listsOf: (String) -> ChainLists;

	private final _byHeld: Map<String, Map<String, CallEdge>> = [];
	private final _graph: CallGraph;
	private final _sinkIds: Array<String>;
	private final _sites: LockSites;
	private final _long: Array<String>;

	public function new(
		graph: CallGraph, sinkIds: Array<String>, listsOf: (String) -> ChainLists, sites: LockSites, long: Array<String>
	) {
		_graph = graph;
		_sinkIds = sinkIds;
		this.listsOf = listsOf;
		_sites = sites;
		_long = long;
	}

	public inline function clear(): Void {
		_byHeld.clear();
	}

	/** The lock `a` takes when its kind is `reentrantLocks`-listed and a member names it; null otherwise. */
	public function reentrantHeld(a: LockAcquire): Null<String> {
		return a.lock != null && listsOf(a.edge.file).reentrantIds.contains(a.pair.lockId) ? a.lock : null;
	}

	/**
	 * Whether `edge` itself blocks under a hold of `held`: a sink call its site's chain names, one taking a lock only
	 * when the lock is long or unknown, and never a re-take of `held`.
	 */
	public function blocks(edge: CallEdge, held: Null<String>): Bool {
		if (!edge.kind.isInvocation() || !listsOf(edge.file).sinkIds.contains(edge.to)) return false;
		if (!takesLock(edge)) return true;
		final lock: Null<String> = _sites.lockOf(edge);
		return lock == null || lock != held && _long.contains(lock);
	}

	/** Whether a hold of `held` spanning `edge` spans a blocking call: `edge` blocks, or reaches a sink through no lock. */
	public function heldAcrossBlocking(edge: CallEdge, held: Null<String>): Bool {
		return blocks(edge, held) || hops(held).exists(edge.to) && !takesLock(edge);
	}

	/**
	 * The taint under a hold of `held`: reverse BFS from the blocking calls over the invocation edges
	 * (`EdgeKind.isInvocation`). A call taking a lock taints its caller by what the lock is (`blocks`), never through the
	 * lock primitive's own body: that body IS the wait.
	 */
	public function hops(held: Null<String>): Map<String, CallEdge> {
		final known: Null<Map<String, CallEdge>> = _byHeld[held ?? ''];
		if (known != null) return known;
		final taintHop: Map<String, CallEdge> = [];
		_byHeld[held ?? ''] = taintHop;
		final queue: Array<String> = [];
		// a node its call site's own chain names a sink is where a chain ENDS: a call to it blocks by that name (`blocks`)
		for (edge in _graph.edges) if (
			_sinkIds.contains(edge.to) && !taintHop.exists(edge.from) && !listsOf(edge.file).sinkIds.contains(edge.from)
			&& blocks(edge, held)
		) {
			taintHop[edge.from] = edge;
			queue.push(edge.from);
		}
		var qi: Int = 0;
		while (qi < queue.length) {
			final id: String = queue[qi++];
			for (edge in _graph.inEdges(id)) if (edge.kind.isInvocation() && !taintHop.exists(edge.from) && !takesLock(edge)) {
				// the edge leaves `from`'s body, so its file's chain is the one that says whether `from` is a sink
				if (listsOf(edge.file).sinkIds.contains(edge.from)) continue;
				taintHop[edge.from] = edge;
				queue.push(edge.from);
			}
		}
		return taintHop;
	}

	/** Whether `edge` is a call to a sink `lockPairs` names a lock of: one whose cost is the wait for that lock. */
	private function takesLock(edge: CallEdge): Bool {
		final lists: ChainLists = listsOf(edge.file);
		return lists.sinkIds.contains(edge.to) && lists.pairs.exists(p -> p.lockId == edge.to);
	}

}
