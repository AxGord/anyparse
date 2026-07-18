package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.ListenerSymmetry;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * The `listener-symmetry` check: an `add<Xxx>Listener(s)` method should have a
 * matching `remove<Xxx>Listener(s)` in the same class/abstract (and the reverse),
 * declared next to it, with matching static-ness. A missing twin, a static-ness
 * mismatch, and a non-adjacent pair are each an `Info`. Report-only — `fix`
 * yields no edits. Interfaces and bare `addListener` (no discriminator) are out
 * of scope; `#if`-guarded members are seen.
 */
class ListenerSymmetryCheckTest extends Test {

	public function testAddWithoutRemoveFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function addFooListener():Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('listener-symmetry', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'addFooListener'"));
		Assert.isTrue(vs[0].message.contains("'removeFooListener'"));
	}

	public function testRemoveWithoutAddFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function removeBarListener():Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'removeBarListener'"));
		Assert.isTrue(vs[0].message.contains("'addBarListener'"));
	}

	public function testAdjacentPairQuiet(): Void {
		Assert.equals(
			0, violations('class C {\n\tpublic function addBazListener():Void {}\n\tpublic function removeBazListener():Void {}\n}').length
		);
	}

	public function testReverseOrderPairQuiet(): Void {
		// remove declared before add, still adjacent -> a valid pair.
		Assert.equals(
			0, violations('class C {\n\tpublic function removeBazListener():Void {}\n\tpublic function addBazListener():Void {}\n}').length
		);
	}

	public function testPluralPairQuiet(): Void {
		// The `Listeners` plurality carries across into the twin name.
		Assert.equals(
			0,
			violations('class C {\n\tpublic function addFooListeners():Void {}\n\tpublic function removeFooListeners():Void {}\n}').length
		);
	}

	public function testNotAdjacentFlaggedOnce(): Void {
		// A method between the pair -> not adjacent; reported once, on the `add`.
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function addQuxListener():Void {}\n\tpublic function mid():Void {}\n\tpublic function removeQuxListener():Void {}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('next to each other'));
		Assert.isTrue(vs[0].message.contains("'addQuxListener'"));
	}

	public function testFieldBetweenBreaksAdjacency(): Void {
		// Adjacency counts ANY member between the pair, not only another method.
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function addQuxListener():Void {}\n\tvar mid:Int;\n\tpublic function removeQuxListener():Void {}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('next to each other'));
	}

	public function testStaticInstanceMismatchFlaggedOnce(): Void {
		// A static add and an instance remove cannot form a pair; reported once.
		final vs: Array<Violation> = violations(
			'class C {\n\tstatic public function addWatListener():Void {}\n\tpublic function removeWatListener():Void {}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('static-ness'));
	}

	public function testStaticPairQuiet(): Void {
		// Both static and adjacent -> a valid pair.
		Assert.equals(
			0,
			violations(
				'class C {\n\tstatic public function addWatListener():Void {}\n\tstatic public function removeWatListener():Void {}\n}'
			).length
		);
	}

	public function testBareAddListenerNotMatched(): Void {
		// No `<Xxx>` discriminator -> not a listener-symmetry candidate.
		Assert.equals(0, violations('class C {\n\tpublic function addListener():Void {}\n}').length);
	}

	public function testUnrelatedNameNotMatched(): Void {
		// `address` starts with `add` but is not `add<Xxx>Listener(s)`.
		Assert.equals(0, violations('class C {\n\tpublic function address():Void {}\n}').length);
	}

	public function testInterfaceMembersNotFlagged(): Void {
		// An interface declares a contract, not the extracted subscribe/unsubscribe
		// helpers this preference is about -> out of scope.
		Assert.equals(0, violations('interface I {\n\tfunction addZapListener():Void;\n}').length);
	}

	public function testConditionalGuardedMemberSeen(): Void {
		// A `#if`-guarded add with no remove is still flagged -> the guarded member is seen.
		final vs: Array<Violation> = violations('class C {\n\t#if js\n\tpublic function addBazListener():Void {}\n\t#end\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'addBazListener'"));
	}

	public function testAbstractContainerChecked(): Void {
		// An abstract is a class-like container -> its listener methods are checked.
		final vs: Array<Violation> = violations('abstract A(Int) {\n\tpublic function addFooListener():Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'removeFooListener'"));
	}

	public function testTwoIndependentMissingPairs(): Void {
		// Two lone methods -> two independent findings.
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function addFooListener():Void {}\n\tpublic function removeBarListener():Void {}\n}'
		);
		Assert.equals(2, vs.length);
	}

	public function testNoqaOnMethodLineSuppresses(): Void {
		// The finding span is the method header line -> a bare noqa there clears it.
		Assert.equals(0, suppressed('class C {\n\tpublic function addFooListener():Void {} // noqa\n}').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tpublic function addFooListener():Void {}\n}';
		final check: ListenerSymmetry = new ListenerSymmetry();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public function addFooListener(').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('listener-symmetry'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('listener-symmetry'));
	}

	private function violations(src: String): Array<Violation> {
		return new ListenerSymmetry().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function suppressed(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new ListenerSymmetry()]);
	}

}
