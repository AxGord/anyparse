package unit.runtime;

import anyparse.runtime.SortedOffsets;
import utest.Assert;
import utest.Test;

/** `SortedOffsets.firstIn`: the smallest offset inside a half-open range, both bounds honoured. */
@:nullSafety(Strict)
final class SortedOffsetsTest extends Test {

	private static final OFFSETS: Array<Int> = [3, 10, 17, 40];

	@:pin('control')
	@:killer('M-SORTED-OFFSETS-LOWER-BLIND')
	public function testAnOffsetBelowTheRangeIsNotInIt(): Void {
		Assert.equals(10, SortedOffsets.firstIn(OFFSETS, 4, 20));
		Assert.equals(17, SortedOffsets.firstIn(OFFSETS, 11, 20));
	}

	@:pin('control')
	@:killer('M-SORTED-OFFSETS-UPPER-BLIND')
	public function testTheUpperBoundIsExclusive(): Void {
		Assert.equals(-1, SortedOffsets.firstIn(OFFSETS, 11, 17));
		Assert.equals(-1, SortedOffsets.firstIn(OFFSETS, 41, 50));
	}

	@:pin('guard')
	public function testTheLowerBoundIsInclusive(): Void {
		Assert.equals(3, SortedOffsets.firstIn(OFFSETS, 3, 4));
		Assert.equals(40, SortedOffsets.firstIn(OFFSETS, 18, 41));
		Assert.equals(-1, SortedOffsets.firstIn([], 0, 10));
	}

}
