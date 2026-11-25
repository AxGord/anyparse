package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.WriteSites.WriteSite;
import anyparse.runtime.Span;

using Lambda;

/** An occurrence, as `SameValueRuns` reads it: where it sits. */
typedef Located = { final span: Span; }

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
	public static function splitAtWrites<T: Located>(sorted: Array<T>, writes: Array<WriteSite>): Array<Array<T>> {
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
	public static function carriedRound<T: Located>(
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
	public static function hoistBlock<T: Located>(run: Array<T>, unit: QueryNode, blockKinds: Array<String>): Null<QueryNode> {
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

	/**
	 * The statement of `block` a local holding `run`'s value may be declared before: the one holding the earliest
	 * occurrence, when that occurrence is evaluated whenever the statement runs (`evaluatedWhenever`) and no write in
	 * `writes` takes effect between the statement's start and it. Null when no such point dominates the run.
	 */
	public static function hoistPoint<T: Located>(
		run: Array<T>, block: QueryNode, writes: Array<WriteSite>, shape: RefShape
	): Null<QueryNode> {
		final first: Int = run[0].span.from;
		final chain: Array<QueryNode> = TreePath.ancestorsAt(block, first);
		final stmt: Null<QueryNode> = chain.length > 1 ? chain[1] : null;
		final from: Null<Int> = stmt?.span?.from;
		if (stmt == null || from == null) return null;
		final start: Int = from;
		return !writes.exists(w -> start < w.effect && w.effect <= first) && evaluatedWhenever(stmt, first, shape) ? stmt : null;
	}

	/**
	 * Whether the expression starting at `at` is evaluated every time `stmt` runs, before any code that may skip it: each
	 * step down evaluates all of its operands (`CtorFieldWrite.unconditionalOperandKinds`, a field or index access, a
	 * return, arithmetic, a comparison), or only its first one for a construct deciding the rest (a condition, `&&`,
	 * `||`, `??`, a ternary). Any other kind — a branch body, a loop body, a closure, a kind the grammar leaves unset —
	 * refuses.
	 */
	public static function evaluatedWhenever(stmt: QueryNode, at: Int, shape: RefShape): Bool {
		final firstOnly: Array<String> = (shape.conditionFirstChildKinds ?? []).concat(shape.branchConditionKinds ?? []);
		for (kind in [
			shape.logicalAndKind,
			shape.logicalOrKind,
			shape.nullCoalesceKind,
			shape.ternaryKind
		]) if (kind != null) firstOnly.push(kind);
		final all: Array<String> = CtorFieldWrite.unconditionalOperandKinds(shape)
			.concat(shape.arithmeticKinds ?? [])
			.concat(shape.comparisonKinds ?? []);
		for (kind in [
			shape.fieldAccessKind,
			shape.indexAccessKind,
			shape.returnStatementKind,
			shape.returnExpressionKind
		]) if (kind != null) all.push(kind);
		function reaches(node: QueryNode): Bool {
			final span: Null<Span> = node.span;
			if (span == null || at < span.from || at >= span.to) return false;
			return span.from == at || (
				firstOnly.contains(node.kind)
					? node.children.length > 0 && reaches(node.children[0])
					: all.contains(node.kind) && node.children.exists(reaches)
			);
		}
		return reaches(stmt);
	}

}
