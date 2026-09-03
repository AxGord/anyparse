package unit;

import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

/**
 * The pin for the failure mode the generated registration exists to end: a
 * test class that NO hand-written line names.
 *
 * The hand-written runner it was measured against — `test/RunTestsLegacy.hx`,
 * 758 `addCase(new X())` lines — did not mention this class, deliberately, and
 * is gone as of the second merged wave. Under that layer this fixture was
 * registered nowhere, ran nowhere, and the transcript said nothing at all
 * about it: that silence was the defect, and it was not observable from inside
 * the old layer. Under discovery the class is found because it extends
 * `utest.Test` and carries a `test`-prefixed method, which is the entire
 * predicate.
 *
 * Nothing registers it by hand today either, and nothing may: a hand-written
 * line anywhere would delete the only standing evidence that discovery — not a
 * list — is what runs this method.
 */
@:nullSafety(Strict)
class DiscoveryOnlyProbeTest extends Test {

	/** Reached only through `testkit.TestRegistry` — nothing registers this class by hand. */
	public function testRunsWithoutAHandWrittenRegistration(): Void {
		Assert.isTrue(
			TestRegistry.classNames().contains('unit.DiscoveryOnlyProbeTest'), 'discovery registered the class this method is running from'
		);
	}

}
