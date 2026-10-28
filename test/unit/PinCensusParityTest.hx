package unit;

import testkit.TestRegistry;
import unit.census.CensusDiff;
import unit.census.PinsCheckAToO;
import unit.census.PinsCheckPToZ;
import unit.census.PinsGrammarAndCli;
import unit.census.PinsQueryAndRuntime;
import utest.Assert;
import utest.Test;

/**
 * Pins the GENERATED pin registry — `TestRegistry.pins()`, every `@:pin` / `@:killer` the
 * build macro `testkit.TestDiscovery` validated — against a hand-kept census, so a pin dropped
 * in a refactor fails here by name. The sibling of `TestDiscoveryParityTest` (the registered
 * classes) and `ArmCensusParityTest` (the arms a `@:killer` resolves into).
 *
 * The census is ALPHABETICAL by `ClassName#testMethod` (matching `TestRegistry.pins()`'s own
 * sort) and lives in `unit.census`, cut by sorted range into parts small enough to grow:
 * `PinsCheckAToO`, `PinsCheckPToZ`, `PinsGrammarAndCli`, `PinsQueryAndRuntime`, concatenated
 * in that order. A new pin goes into the part whose range holds it, placed by
 * `node bin/dev.js census --write`. The assertion reports a computed missing/extra diff on failure
 * (`CensusDiff.diffedMsg`) instead of naming only the failing test method.
 */
@:nullSafety(Strict)
class PinCensusParityTest extends Test {

	/**
	 * The metadata pilot, read back through the macro that validates it.
	 *
	 * `@:pin` names what a fixture is FOR and `@:killer` the mutation arm that
	 * must break it; `testkit.TestDiscovery` refuses to build a `control`
	 * naming no arm, which is a compile error and therefore has no fixture of
	 * its own — this is the runtime half, and it is what keeps the metas from
	 * being dropped in a refactor without anything noticing.
	 *
	 * Hundreds of entries over dozens of classes, and still not a conversion of the tree: some
	 * are the seam coverage for the rules a slice touched that its deciding arm cannot reach
	 * (docs/testing.md § "Rules the deciding arm cannot reach are pinned one fixture per rule"),
	 * where the arm name is the whole point — it is the only record that the fixture reaches the
	 * moved code, and deleting the fixture now fails HERE rather than silently.
	 */
	public function testThePilotPinsReachTheGeneratedRegistry(): Void {
		final expectedPins: Array<String> = PinsCheckAToO.PINS.concat(PinsCheckPToZ.PINS)
			.concat(PinsGrammarAndCli.PINS)
			.concat(PinsQueryAndRuntime.PINS);
		final actualPins: Array<String> = TestRegistry.pins();
		Assert.same(
			expectedPins, actualPins,
			CensusDiff.diffedMsg(expectedPins, actualPins, 'the pin annotations, with their roles and killing arms')
		);
	}

}
