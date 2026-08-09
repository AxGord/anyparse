package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.FixVerifier;

using Lambda;

/**
 * Unit coverage of `FixVerifier.isolateFailers` — the bisect that replaces the old
 * whole-file revert when a risky-fix edit set fails the oracle. It searches over UNIT
 * indices (one unit per edit, or per `GroupedFix` group — `verifyEntry` owns that
 * mapping), and every fixture here drives the ungrouped shape, where a unit IS an edit.
 * Driven by a deterministic FAKE probe (no compiler): independent failers isolate
 * exactly, a failing PAIR yields a SAFE complement (the property that matters, not a
 * specific index set), and an over-tight budget falls back to `null` for the caller to
 * revert the whole file. The internal bisect is reached through `@:access`.
 */
@:access(anyparse.check.FixVerifier)
@:nullSafety(Strict)
class FixVerifierBisectTest extends Test {

	public function testSingleFailerIsolatedExactly(): Void {
		final spent: Array<Int> = [0];
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(8, 100, independentProbe([3]), spent);
		Assert.same([3], failers);
	}

	public function testSingleFailerWithinExactBudget(): Void {
		// 2*ceil(log2(8)) = 6 probes suffice for one failer — no fallback at the exact search budget.
		final spent: Array<Int> = [0];
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(8, 6, independentProbe([3]), spent);
		Assert.same([3], failers);
		Assert.isTrue(spent[0] <= 6, 'a single failer stays within the 2*ceil(log2(N)) search budget (spent ${spent[0]})');
	}

	public function testBoundaryFailersIsolated(): Void {
		Assert.same([0], FixVerifier.isolateFailers(5, 100, independentProbe([0]), [0]));
		Assert.same([4], FixVerifier.isolateFailers(5, 100, independentProbe([4]), [0]));
	}

	public function testTwoSpreadFailersIsolated(): Void {
		final spent: Array<Int> = [0];
		final probe: Array<Int> -> Bool = independentProbe([1, 6]);
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(8, 100, probe, spent);
		Assert.same([1, 6], failers);
		assertComplementSafe(8, failers, probe);
	}

	public function testFailingPairStraddlingSplitIsSafe(): Void {
		// (0, 7) straddle the midpoint: both halves pass alone, the union fails. The
		// bisect cannot name the pair, but the complement it applies MUST typecheck.
		final probe: Array<Int> -> Bool = pairProbe(0, 7);
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(8, 100, probe, [0]);
		assertComplementSafe(8, failers, probe);
		assertBreaksPair(failers, 0, 7);
	}

	public function testFailingPairWithinHalfIsSafe(): Void {
		// (1, 2) land in the same half; the sub-split still cannot name them, but the
		// applied complement must typecheck.
		final probe: Array<Int> -> Bool = pairProbe(1, 2);
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(8, 100, probe, [0]);
		assertComplementSafe(8, failers, probe);
		assertBreaksPair(failers, 1, 2);
	}

	public function testCapFallbackReturnsNull(): Void {
		// Two spread failers need ~10 probes; the single-failer search budget (6) is too
		// tight, so the search exhausts it and falls back (null) — the caller reverts whole.
		final spent: Array<Int> = [0];
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(8, 6, independentProbe([0, 7]), spent);
		Assert.isNull(failers, 'an over-tight budget falls back to a whole-file revert (null)');
		Assert.equals(6, spent[0], 'the search stops exactly at the budget');
	}

	public function testManyIndependentFailersFallBack(): Void {
		// Every edit fails alone — the search fans into both halves at every level and
		// blows the budget, so it falls back rather than probing ~2N times.
		final all: Array<Int> = [for (i in 0...8) i];
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(8, 6, independentProbe(all), [0]);
		Assert.isNull(failers);
	}

	public function testCeilLog2(): Void {
		Assert.equals(0, FixVerifier.ceilLog2(1));
		Assert.equals(1, FixVerifier.ceilLog2(2));
		Assert.equals(2, FixVerifier.ceilLog2(3));
		Assert.equals(2, FixVerifier.ceilLog2(4));
		Assert.equals(3, FixVerifier.ceilLog2(5));
		Assert.equals(3, FixVerifier.ceilLog2(8));
		Assert.equals(4, FixVerifier.ceilLog2(9));
	}

	private function assertComplementSafe(count: Int, failers: Null<Array<Int>>, probe: Array<Int> -> Bool): Void {
		Assert.notNull(failers);
		if (failers == null) return;
		final safeFailers: Array<Int> = failers;
		final complement: Array<Int> = [for (i in 0...count) if (!safeFailers.contains(i)) i];
		Assert.isTrue(probe(complement), 'the complement of the isolated failers must typecheck');
	}

	private function assertBreaksPair(failers: Null<Array<Int>>, a: Int, b: Int): Void {
		Assert.notNull(failers);
		if (failers == null) return;
		final safeFailers: Array<Int> = failers;
		Assert.isTrue(safeFailers.contains(a) || safeFailers.contains(b), 'at least one member of the failing pair must be reverted');
	}

	/** A subset typechecks unless it holds a member of `failers` (independent failers). */
	private static inline function independentProbe(failers: Array<Int>): Array<Int> -> Bool {
		return subset -> !subset.exists(i -> failers.contains(i));
	}

	/** A subset typechecks unless it holds BOTH `a` and `b` (a failing pair). */
	private static inline function pairProbe(a: Int, b: Int): Array<Int> -> Bool {
		return subset -> !(subset.contains(a) && subset.contains(b));
	}

}
