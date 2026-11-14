package unit.format;

import anyparse.query.FormatFixedPoint;

/**
 * A threshold-pivot object literal enclosing a `fillLine` array of
 * parenthesised type-checks reaches the writer's fixed point in one write.
 */
@:nullSafety(Strict)
@:access(unit.format.WrapFlatSourceFixedPointTest)
class StackedArrayPivotOneWriteTest extends Test {

	@:pin('control')
	@:killer('M-SOURCE-FLOOR-ALWAYS')
	public function testOneWriteReachesFixedPoint(): Void {
		final result: FormatFixedPointResult = FormatFixedPoint.run(
			s -> WrapFlatSourceFixedPointTest.write(s, WrapFlatSourceFixedPointTest.STACKED_ARRAY_PIVOT),
			WrapFlatSourceFixedPointTest.STACKED_SRC
		);
		Assert.isTrue(result.converged, 'must converge: ${result.failure}');
		Assert.equals(1, result.rewrites, 'one write must reach the fixed point:\n<${result.text}>');
	}

}
