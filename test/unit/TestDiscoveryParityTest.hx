package unit;

import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Pins the GENERATED registration layer — `testkit.TestRegistry`, built by
 * `testkit.TestDiscovery`.
 *
 * `test/RunTests.hx` used to carry a hand-written `addCase(new X())` line and
 * an import per class. The cost was never the typing: a class whose line
 * was never added ran nowhere and said nothing, and no gate had an artifact
 * to compare against. This class pins what discovery reports beside it.
 *
 * WHICH classes register is not pinned here: the build macro holds it, since
 * every `*Test.hx` file must register exactly one class and every registered
 * class must live in one, so narrowing the discovery predicate stops the build
 * naming the file it dropped. A hand-kept list of the names used to mirror the
 * registry; it caught nothing the file diff did not already show and every
 * slice had to merge it.
 *
 * What is deliberately NOT pinned here is per-METHOD parity. utest decides
 * what a fixture is (`!isStatic` and a `test`/`spec` name prefix) and
 * `TestDiscovery` asks utest's own question, so the two cannot disagree by
 * construction; the per-class per-method census that proved it across the
 * switch-over is in the slice report, not in a fixture that would have to be
 * regenerated on every test added.
 *
 * The pins and the arms need no list either: `@:pin` / `@:killer` live on the
 * fixtures, the arms in `mutation-arms.json`, and the build refuses a dangling
 * killer, an arm nobody names and an arm whose member is gone.
 */
@:nullSafety(Strict)
class TestDiscoveryParityTest extends Test {

	/**
	 * `utest.Test` subclasses carrying no fixture of their own or inherited.
	 *
	 * Registering one would be a no-op — `Runner.addITest` builds no fixture
	 * for it either and stores no entry — so discovery reports them instead
	 * of registering them, and this pin is what keeps "reports" from decaying
	 * into "silently drops".
	 *
	 * Five are shared bases for one check's tests. The sixth,
	 * `unit.grammar.haxe.HxTestHelpers`, reads like the surprise and is not
	 * one: the `Hx*` test classes extend it, so its `extends utest.Test` is
	 * what makes each of THEM a `utest.ITest`. It carries parse / round-trip
	 * helpers and no fixture of its own, which is exactly why discovery
	 * reports it rather than registering it.
	 */
	private static final EXPECTED_BASE_CLASSES: Array<String> = [
		'unit.check.ExplicitLocalTypeCheckTestBase',
		'unit.check.FoldStringLiteralsCheckTestBase',
		'unit.check.NamingCheckTestBase',
		'unit.check.RedundantParensOperandArmsTestBase',
		'unit.check.TrivialGetterCheckTestBase',
		'unit.grammar.haxe.HxTestHelpers'
	];

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
			'unit.DiscoveryOnlyProbeTest carries no hand-written registration anywhere, on purpose'
		);
	}

	/**
	 * A fixture-named method utest will never run — `static function testX`,
	 * or one on a class that does not implement `utest.ITest`. The tree has
	 * none today; this pin is what makes the first one arrive loudly instead
	 * of joining the dead methods a build guard once hid.
	 */
	public function testTheDeadFixtureCensusIsEmpty(): Void {
		Assert.same([], TestRegistry.deadTests(), 'no fixture-named method is unreachable to utest');
	}

	public function testFixturelessSubclassesAreReportedRatherThanRegistered(): Void {
		Assert.same(EXPECTED_BASE_CLASSES, TestRegistry.baseClasses(), 'the reported no-fixture subclasses');
		final registered: Array<String> = TestRegistry.classNames();
		for (name in EXPECTED_BASE_CLASSES)
			Assert.isFalse(registered.contains(name), '$name carries no fixture, so registering it would be a no-op');
	}

}
