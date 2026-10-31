package unit.runtime;

import anyparse.runtime.SameItems;

/** `SameItems.of`: same length and the same item at every index — order counts, a length match alone does not. */
@:nullSafety(Strict)
final class SameItemsTest extends Test {

	@:pin('control')
	@:killer('M-SAMEITEMS-LENGTH-ONLY')
	public function testSameLengthDifferentItemsDiffer(): Void {
		Assert.isFalse(SameItems.of(['a', 'b'], ['a', 'c']));
		Assert.isFalse(SameItems.of([1, 2], [2, 1]));
	}

	/** M-SAMEITEMS-LENGTH-ONLY only widens sameness; equal items stay the same, so this case stays green. */
	@:pin('guard') // noqa: guard-pin-arm-reach
	public function testEqualItemsInOrderAreTheSame(): Void {
		Assert.isTrue(SameItems.of(['a', 'b'], ['a', 'b']));
		Assert.isTrue(SameItems.of(([]: Array<Int>), []));
	}

	/** M-SAMEITEMS-LENGTH-ONLY still compares lengths, so different lengths still differ and this case stays green. */
	@:pin('guard') // noqa: guard-pin-arm-reach
	public function testDifferentLengthsDiffer(): Void {
		Assert.isFalse(SameItems.of(['a'], ['a', 'b']));
	}

}
