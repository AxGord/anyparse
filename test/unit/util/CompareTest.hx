package unit.util;

import anyparse.util.Compare;

/** `Compare`: three-way comparators that return exactly -1, 0 or 1 and order strings by code unit. */
final class CompareTest extends Test {

	@:pin('control')
	@:killer('M-UTIL-COMPARE-INT-LESS')
	public function testASmallerIntegerComesFirst(): Void {
		Assert.equals(-1, Compare.compareInt(1, 2));
		Assert.equals(-1, Compare.compareInt(-3, -2));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-INT-MORE')
	public function testALargerIntegerComesLast(): Void {
		Assert.equals(1, Compare.compareInt(2, 1));
		Assert.equals(1, Compare.compareInt(-2, -3));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-INT-EQUAL')
	public function testEqualIntegersCompareAsZero(): Void {
		Assert.equals(0, Compare.compareInt(2, 2));
		Assert.equals(0, Compare.compareInt(0, 0));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-LESS')
	public function testASmallerStringComesFirst(): Void {
		Assert.equals(-1, Compare.compareString('a', 'b'));
		Assert.equals(-1, Compare.compareString('ab', 'abc'));
		Assert.equals(-1, Compare.compareString('', 'a'));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-MORE')
	public function testALargerStringComesLast(): Void {
		Assert.equals(1, Compare.compareString('b', 'a'));
		Assert.equals(1, Compare.compareString('abc', 'ab'));
		Assert.equals(1, Compare.compareString('a', ''));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-EQUAL')
	public function testEqualStringsCompareAsZero(): Void {
		Assert.equals(0, Compare.compareString('ab', 'ab'));
		Assert.equals(0, Compare.compareString('', ''));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-CASE')
	public function testStringsOrderByCodeUnitNotByLetter(): Void {
		Assert.equals(-1, Compare.compareString('Z', 'a'));
		Assert.equals(1, Compare.compareString('a', 'B'));
	}

	public function testItSortsAnArrayTheSameWayEveryTime(): Void {
		final names: Array<String> = ['b', 'B', 'a', 'ab', ''];
		names.sort(Compare.compareString);
		Assert.same(['', 'B', 'a', 'ab', 'b'], names);
		final numbers: Array<Int> = [3, -1, 2, 2];
		numbers.sort(Compare.compareInt);
		Assert.same([-1, 2, 2, 3], numbers);
	}

}
