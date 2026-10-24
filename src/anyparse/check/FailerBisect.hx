package anyparse.check;

import haxe.Exception;

/**
 * Binary-split group testing over units known to fail together: the search `FixVerifier` bisects a rejected risky edit
 * set with, and the safe-pass net (`LintFixSafePass.isolate`) bisects a rejected wave with. Index-agnostic — the caller
 * maps an index to whatever a unit is (an edit, an edit group, a file, one rule's edits in a file) and answers each probe.
 */
@:nullSafety(Strict)
final class FailerBisect {

	/**
	 * The probe budget of a search over `n` units: `2*ceil(log2(n))` isolates a single failing unit without
	 * falling back, and several scattered failers exhaust it rather than probing every unit.
	 */
	public static inline function searchBudget(n: Int): Int {
		return 2 * ceilLog2(n);
	}

	/**
	 * Isolate the failing UNIT indices among `[0, count)` by binary-split group
	 * testing. `probe(indices)` is true when the candidate holding exactly that SUBSET
	 * of units typechecks. Precondition: the FULL set is known to fail, so no probe
	 * re-establishes it. Returns the sorted failer indices whose removal makes the
	 * complement pass — a complement the caller still confirms before keeping it — or
	 * null when the probe budget is exhausted (the caller falls back to reverting the
	 * whole set). `spent[0]` receives the probe count.
	 */
	public static function isolateFailers(count: Int, budget: Int, probe: Array<Int> -> Bool, spent: Array<Int>): Null<Array<Int>> {
		spent[0] = 0;
		return try bisectRec([for (i in 0...count) i], probe, budget, spent) catch (_: BudgetExceeded) null;
	}

	/** Smallest `k` with `2^k >= n` (the integer ceil of log2), for `n >= 1`. */
	public static function ceilLog2(n: Int): Int {
		var k: Int = 0;
		var v: Int = 1;
		while (v < n) {
			v <<= 1;
			k++;
		}
		return k;
	}

	/**
	 * Recurse over a KNOWN-FAILING index block. A singleton is the failer. Otherwise
	 * split in half and probe each: recurse into a failing half, keep a passing one.
	 * When BOTH halves pass alone yet the block fails, the failure is a cross-half
	 * interaction (e.g. a failing pair straddling the split) — keep the passing left
	 * half and treat the right as the failers; the caller's confirm validates the
	 * whole complement.
	 */
	private static function bisectRec(indices: Array<Int>, probe: Array<Int> -> Bool, budget: Int, spent: Array<Int>): Array<Int> {
		if (indices.length <= 1) return indices;
		final mid: Int = indices.length >> 1;
		final left: Array<Int> = indices.slice(0, mid);
		final right: Array<Int> = indices.slice(mid);
		final leftPasses: Bool = countedProbe(left, probe, budget, spent);
		final rightPasses: Bool = countedProbe(right, probe, budget, spent);
		if (leftPasses && rightPasses) return right.copy();
		final failers: Array<Int> = [];
		if (!leftPasses) for (i in bisectRec(left, probe, budget, spent)) failers.push(i);
		if (!rightPasses) for (i in bisectRec(right, probe, budget, spent)) failers.push(i);
		return failers;
	}

	/** One budget-guarded probe; the call that would exceed `budget` throws `BudgetExceeded`. */
	private static function countedProbe(indices: Array<Int>, probe: Array<Int> -> Bool, budget: Int, spent: Array<Int>): Bool {
		if (spent[0] >= budget) throw new BudgetExceeded();
		spent[0]++;
		return probe(indices);
	}

}

/** Internal control-flow signal: the bisect probe budget was exhausted. */
private class BudgetExceeded extends Exception {

	public function new() {
		super('failer bisect budget exceeded');
	}

}
