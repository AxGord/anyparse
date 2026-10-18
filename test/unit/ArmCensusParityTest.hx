package unit;

import testkit.TestRegistry;
import unit.census.CensusDiff;
import unit.census.DeclaredArms1;
import unit.census.DeclaredArms2;
import unit.census.DeclaredArms3;
import unit.census.DeferredArms;
import utest.Assert;
import utest.Test;

/**
 * Pins the GENERATED arm registries — `TestRegistry.arms()` and `TestRegistry.deferredArms()`,
 * read by `testkit.TestDiscovery` from `test/testkit/mutation-arms.json` — against hand-kept
 * censuses, so an arm that vanished or was renamed fails here by name. The sibling of
 * `TestDiscoveryParityTest` (the registered classes) and `PinCensusParityTest` (the pins).
 *
 * Both censuses follow `test/testkit/mutation-arms.json`'s own DECLARATION order, not
 * alphabetical — a new arm is appended where the JSON puts it, not where it would sort. They
 * live in `unit.census`: the arm names in `DeclaredArms1`..`DeclaredArms3` (concatenated in
 * that order; only the LAST part takes appends), the deferred arms in `DeferredArms`. The arm
 * assertion reports a computed missing/extra diff on failure (`CensusDiff.diffedMsg`).
 */
@:nullSafety(Strict)
class ArmCensusParityTest extends Test {

	/**
	 * The arm registry reaches the generated registry, by NAME.
	 *
	 * Same trade as `TestDiscoveryParityTest.REGISTERED_CLASSES` and no stronger: this is derived
	 * from the very table `TestDiscovery` validated, so it cannot catch a WRONG
	 * arm — only a silently vanished or renamed one, which is the failure a
	 * `@:killer` cannot report because the build would have stopped first. The
	 * names are pinned rather than the rendered lines: an arm's note is prose, and
	 * rewording it should not be a test edit.
	 */
	public function testTheArmRegistryReachesTheGeneratedRegistry(): Void {
		final expectedArms: Array<String> = DeclaredArms1.ARMS.concat(DeclaredArms2.ARMS).concat(DeclaredArms3.ARMS);
		final actualArms: Array<String> = [for (line in TestRegistry.arms()) line.split(' :: ')[0]];
		Assert.same(expectedArms, actualArms, CensusDiff.diffedMsg(expectedArms, actualArms, 'the arms every @:killer resolves into'));
	}

	/**
	 * The arms whose type the typer could not see, and the reason the registry can
	 * declare them at all.
	 *
	 * `anyparse/macro/*` is behind `#if macro`, so a non-macro build types none of it and
	 * `Context.getModule` answers `ok, 0 type(s)` rather than throwing. That answer used to
	 * be collapsed with a module the classpath does not carry, and the whole
	 * macro-time half of the engine was unaddressable by an arm. This census is the build
	 * macro naming what it handed on; `unit.MutationArmAddressTest` is what answers it,
	 * out of the parser rather than the typer.
	 */
	public function testTheDeferredArmCensusNamesTheMacroModuleArms(): Void {
		Assert.same(DeferredArms.ARMS, TestRegistry.deferredArms(), 'the arms the typer could not answer for');
	}

}
