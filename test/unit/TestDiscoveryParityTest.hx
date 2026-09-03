package unit;

import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Pins the GENERATED registration layer — `testkit.TestRegistry`, built by
 * `testkit.TestDiscovery`.
 *
 * `test/RunTests.hx` used to carry 758 hand-written `addCase(new X())` lines
 * and their 758 imports. The cost was never the typing: a class whose line
 * was never added ran nowhere and said nothing, and no gate had an artifact
 * to compare against. This class is that artifact.
 *
 * THE SHAPE IS T130's — the shrinkage IS the acceptance test. The class
 * count is pinned, so narrowing the discovery predicate by one class turns
 * the suite red instead of quietly running 759. That trades one silent
 * failure for one loud chore: adding a test class now needs this number
 * bumped, and the failure message says so.
 *
 * What is deliberately NOT pinned here is per-METHOD parity. utest decides
 * what a fixture is (`!isStatic` and a `test`/`spec` name prefix) and
 * `TestDiscovery` asks utest's own question, so the two cannot disagree by
 * construction; the per-class per-method census that proved it across the
 * switch-over is in the slice report, not in a fixture that would have to be
 * regenerated on every test added.
 */
@:nullSafety(Strict)
class TestDiscoveryParityTest extends Test {

	/**
	 * How many classes discovery must register.
	 *
	 * Bump it when you add or remove a test class. That is the whole
	 * maintenance cost of this layer, and what it replaced was a missing
	 * `addCase` line that nothing reports.
	 */
	private static inline final REGISTERED_CLASSES: Int = 760;

	/**
	 * `utest.Test` subclasses carrying no fixture of their own or inherited.
	 *
	 * Registering one would be a no-op — `Runner.addITest` builds no fixture
	 * for it either and stores no entry — so discovery reports them instead
	 * of registering them, and this pin is what keeps "reports" from decaying
	 * into "silently drops". Five are shared bases for one check's tests;
	 * `unit.HxTestHelpers` extends `utest.Test` for no reason anyone recorded
	 * and is the one that would otherwise have been a surprise.
	 */
	private static final EXPECTED_BASE_CLASSES: Array<String> = [
		'unit.ExplicitLocalTypeCheckTestBase',
		'unit.FoldStringLiteralsCheckTestBase',
		'unit.HxTestHelpers',
		'unit.NamingCheckTestBase',
		'unit.RedundantParensOperandArmsTestBase',
		'unit.TrivialGetterCheckTestBase'
	];

	public function testDiscoveryRegistersExactlyTheCensusedClassCount(): Void {
		Assert.equals(
			REGISTERED_CLASSES, TestRegistry.classNames().length, 'bump REGISTERED_CLASSES when a test class is added or removed'
		);
	}

	/** `Runner.addITest` throws "Cannot add the same test twice" — this fails first, and says why. */
	public function testNoClassIsRegisteredTwice(): Void {
		final names: Array<String> = TestRegistry.classNames();
		final seen: Array<String> = [];
		for (name in names) if (!seen.contains(name)) seen.push(name);
		Assert.equals(names.length, seen.length, 'a duplicate registration makes utest throw at run start');
	}

	/**
	 * The generated names have to be the spelling `Type.getClassName` produces:
	 * that is what the `APQ_TEST` filter matches on and what
	 * `apq shard-plan --classes` deals.
	 */
	public function testEveryRegisteredNameResolvesToARealClass(): Void {
		final unresolved: Array<String> = TestRegistry.classNames().filter(name -> Type.resolveClass(name) == null);
		Assert.same([], unresolved, 'every registered name resolves at runtime');
	}

	/** The whole point, stated once: a class no hand-written line names still runs. */
	public function testTheDiscoveryOnlyFixtureIsRegistered(): Void {
		Assert.isTrue(
			TestRegistry.classNames().contains('unit.DiscoveryOnlyProbeTest'),
			'unit.DiscoveryOnlyProbeTest is absent from test/RunTestsLegacy.hx on purpose'
		);
	}

	/**
	 * A fixture-named method utest will never run — `static function testX`,
	 * or one on a class that does not implement `utest.ITest`. The tree has
	 * none today; this pin is what makes the first one arrive loudly instead
	 * of joining the 167 dead methods S48 found.
	 */
	public function testTheDeadFixtureCensusIsEmpty(): Void {
		Assert.same([], TestRegistry.deadTests(), 'no fixture-named method is unreachable to utest');
	}

	/**
	 * The metadata pilot, read back through the macro that validates it.
	 *
	 * `@:pin` names what a fixture is FOR and `@:killer` the mutation arm that
	 * must break it; `testkit.TestDiscovery` refuses to build a `control`
	 * naming no arm, which is a compile error and therefore has no fixture of
	 * its own — this is the runtime half, and it is what keeps the metas from
	 * being dropped in a refactor without anything noticing.
	 *
	 * Two entries, one class, on purpose: the tree is NOT converted.
	 */
	public function testThePilotPinsReachTheGeneratedRegistry(): Void {
		Assert.same([
			'unit.ComplexItemKindsSeamTest#testTheGeneratedPredicateAnswersTheClassifier :: control :: M-KINDS',
			'unit.ComplexItemKindsSeamTest#testTheTriviaFamilyCarriesTheSameEntry :: seam :: '
		], TestRegistry.pins(), 'the pilot annotations, with their roles and killing arms');
	}

	public function testFixturelessSubclassesAreReportedRatherThanRegistered(): Void {
		Assert.same(EXPECTED_BASE_CLASSES, TestRegistry.baseClasses(), 'the reported no-fixture subclasses');
		final registered: Array<String> = TestRegistry.classNames();
		for (name in EXPECTED_BASE_CLASSES)
			Assert.isFalse(registered.contains(name), '$name carries no fixture, so registering it would be a no-op');
	}

}
