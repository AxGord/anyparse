package anyparse.query;

import anyparse.query.WriteSites.WriteSite;
import anyparse.runtime.Span;

using Lambda;

/**
 * Which occurrences of one expression read one value, and the statement list one local holding it could go into: the
 * one answer to "does a write cut these occurrences apart, and where can they be bound once".
 *
 * Decided from positions over the `WriteSites` a caller has already narrowed to the storage its expression reads; a
 * write that may run elsewhere than its position says (a closure) stays the caller's question (`UnchangedLocal`).
 */
@:nullSafety(Strict)
final class SameValueRuns {

	/** `sorted` cut before every occurrence some write in `writes` takes effect ahead of, since the previous one. */
	public static function splitAtWrites<T:Located>(sorted: Array<T>, writes: Array<WriteSite>): Array<Array<T>> {
		final runs: Array<Array<T>> = [[sorted[0]]];
		for (k in 1...sorted.length) {
			final prev: Int = sorted[k - 1].span.from;
			final cur: Int = sorted[k].span.from;
			if (writes.exists(w -> prev < w.effect && w.effect <= cur))
				runs.push([sorted[k]]);
			else
				runs[runs.length - 1].push(sorted[k]);
		}
		return runs;
	}

	/**
	 * Whether a loop's back edge carries one of `writes` into `run`: the loop holds the write and an occurrence, and
	 * the statement list a shared `final` would go into (`hoistBlock`) is not inside that loop — so no iteration
	 * recomputes the value before the occurrence reads it again. Positive: with no such list, every such loop carries.
	 */
	public static function carriedRound<T:Located>(
		run: Array<T>, writes: Array<WriteSite>, unit: QueryNode, blockKinds: Array<String>, loopKinds: Array<String>
	): Bool {
		final home: Null<QueryNode> = hoistBlock(run, unit, blockKinds);
		inline function recomputed(loop: QueryNode): Bool {
			return home != null && home != loop && TreePath.covers(loop, home.span);
		}
		for (w in writes)
			for (loop in TreePath.ancestorsAt(unit, w.effect - 1))
				if (loopKinds.contains(loop.kind) && !recomputed(loop) && run.exists(c -> TreePath.covers(loop, c.span))) return true;
		return false;
	}

	/** The innermost `blockKinds` node of `unit` holding every occurrence of `run` — the statement list a shared `final` goes into. */
	public static function hoistBlock<T:Located>(run: Array<T>, unit: QueryNode, blockKinds: Array<String>): Null<QueryNode> {
		var common: Array<QueryNode> = TreePath.ancestorsAt(unit, run[0].span.from);
		for (c in run) {
			final chain: Array<QueryNode> = TreePath.ancestorsAt(unit, c.span.from);
			var n: Int = 0;
			while (n < common.length && n < chain.length && common[n] == chain[n]) n++;
			common = common.slice(0, n);
		}
		var i: Int = common.length - 1;
		while (i >= 0 && !blockKinds.contains(common[i].kind)) i--;
		return i >= 0 ? common[i] : null;
	}

}

/** An occurrence, as `SameValueRuns` reads it: where it sits. */
typedef Located = {
	final span: Span;
}
