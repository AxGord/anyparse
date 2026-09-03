package unit;

import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

/**
 * The pin for the failure mode the generated registration exists to end: a
 * test class that NO hand-written line names.
 *
 * `test/RunTestsLegacy.hx` — the runner as it was, with its 758
 * `addCase(new X())` lines — does not mention this class, deliberately and
 * permanently. Under that layer this fixture is registered nowhere, runs
 * nowhere, and the transcript says nothing at all about it: that silence is
 * the defect, and it is not observable from inside the old layer. Under
 * discovery the class is found because it extends `utest.Test` and carries a
 * `test`-prefixed method, which is the entire predicate.
 *
 * So the two builds differ by exactly this fixture plus
 * `unit.TestDiscoveryParityTest`'s, and that difference is the measurement
 * the switch-over rests on.
 *
 * Leave it out of the legacy list for as long as that file exists. Adding a
 * line there would delete the only evidence this slice has.
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
