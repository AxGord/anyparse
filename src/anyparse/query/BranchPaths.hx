package anyparse.query;

import anyparse.runtime.Span;

/**
 * Which occurrences in one function body can run in one execution of it: the one answer to "do these two sit in different
 * branches of one conditional, and how many of a set run at most on one path". A step is a branch child — a child past
 * the first — of a node of the caller's conditional kinds (an `if`, a `switch`); two occurrences taking different steps
 * of one conditional never both run.
 */
@:nullSafety(Strict)
final class BranchPaths {

	/** The branch steps from `unit` down to `node`, outermost first; empty when `unit` does not hold it. */
	public static function of(unit: QueryNode, node: QueryNode, conditionalKinds: Array<String>): Array<BranchStep> {
		final chain: Array<QueryNode> = TreePath.pathAround(unit, node) ?? [];
		final out: Array<BranchStep> = [];
		for (i in 0...chain.length - 1) {
			final at: Null<Span> = chain[i].span;
			final idx: Int = chain[i].children.indexOf(chain[i + 1]);
			if (at != null && idx >= 1 && conditionalKinds.contains(chain[i].kind)) out.push({ key: '${at.from}:${at.to}', idx: idx });
		}
		return out;
	}

	/** Whether two branch paths diverge at a shared conditional — different branch children of one `if` / `switch`. */
	public static function exclusive(a: Array<BranchStep>, b: Array<BranchStep>): Bool {
		for (sa in a) for (sb in b) if (sa.key == sb.key && sa.idx != sb.idx) return true;
		return false;
	}

	/** Whether every pair of `paths` is exclusive — so at most one of them runs per execution. */
	public static function allPairsExclusive(paths: Array<Array<BranchStep>>): Bool {
		for (i => a in paths) for (j in i + 1...paths.length) if (!exclusive(a, paths[j])) return false;
		return true;
	}

	/**
	 * The most of `paths` one execution runs: each outside every branch counts, and of the branches of one conditional
	 * only the one that runs the most.
	 */
	public static function mostOnOnePath(paths: Array<Array<BranchStep>>): Int {
		var total: Int = 0;
		final keys: Array<String> = [];
		final arms: Map<String, Map<Int, Array<Array<BranchStep>>>> = [];
		for (p in paths) {
			if (p.length == 0) {
				total++;
				continue;
			}
			final head: BranchStep = p[0];
			final byArm: Map<Int, Array<Array<BranchStep>>> = arms[head.key] ?? [];
			if (!arms.exists(head.key)) {
				arms[head.key] = byArm;
				keys.push(head.key);
			}
			final tails: Array<Array<BranchStep>> = byArm[head.idx] ?? [];
			tails.push(p.slice(1));
			byArm[head.idx] = tails;
		}
		for (k in keys) {
			var most: Int = 0;
			for (tails in arms[k] ?? []) {
				final n: Int = mostOnOnePath(tails);
				if (n > most) most = n;
			}
			total += most;
		}
		return total;
	}

}

/** One branch taken on the way to an occurrence: the conditional (by its span) and the index of the child entered. */
typedef BranchStep = {
	final key: String;
	final idx: Int;
}
