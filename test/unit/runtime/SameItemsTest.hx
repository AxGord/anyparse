package unit.runtime;

import anyparse.runtime.SameItems;
import utest.Assert;
import utest.Test;

/** `SameItems.of`: same length and the same item at every index — order counts, a length match alone does not. */
@:nullSafety(Strict)
final class SameItemsTest extends Test {

	@:pin('control')
	@:killer('M-SAMEITEMS-LENGTH-ONLY')
	public function testSameLengthDifferentItemsDiffer(): Void {
		Assert.isFalse(SameItems.of(['a', 'b'], ['a', 'c']));
		Assert.isFalse(SameItems.of([1, 2], [2, 1]));
	}

	@:pin('guard')
	public function testEqualItemsInOrderAreTheSame(): Void {
		Assert.isTrue(SameItems.of(['a', 'b'], ['a', 'b']));
		Assert.isTrue(SameItems.of(([]: Array<Int>), []));
	}

	@:pin('guard')
	public function testDifferentLengthsDiffer(): Void {
		Assert.isFalse(SameItems.of(['a'], ['a', 'b']));
	}

}
