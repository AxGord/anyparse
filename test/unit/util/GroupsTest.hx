package unit.util;

using anyparse.util.Groups;

/** `Groups.pushAllUnique`: every source element enters the target once, in first-seen order, under `pushUnique`'s equality. */
final class GroupsTest extends Test {

	@:pin('control')
	@:killer('M-UTIL-PUSH-ALL-UNIQUE-REPEAT')
	public function testAValueTheTargetHoldsIsNotAppendedAgain(): Void {
		final xs: Array<Int> = [1, 2];
		xs.pushAllUnique([2, 3, 1]);
		Assert.same([1, 2, 3], xs);
	}

	@:pin('control')
	@:killer('M-UTIL-PUSH-ALL-UNIQUE-REPEAT')
	public function testAValueTheSourceRepeatsIsAppendedOnce(): Void {
		final xs: Array<Int> = [];
		xs.pushAllUnique([4, 4, 5, 4]);
		Assert.same([4, 5], xs);
	}

	@:pin('control')
	@:killer('M-UTIL-PUSH-ALL-UNIQUE-ORDER')
	public function testNewValuesKeepTheSourcesFirstSeenOrder(): Void {
		final xs: Array<String> = ['z'];
		xs.pushAllUnique(['c', 'a', 'b', 'a']);
		Assert.same(['z', 'c', 'a', 'b'], xs);
	}

	@:pin('control')
	@:killer('M-UTIL-PUSH-ALL-UNIQUE-REPEAT')
	public function testAnyIterableIsASource(): Void {
		final byKey: Map<Int, String> = [1 => 'x', 2 => 'x', 3 => 'y'];
		final xs: Array<String> = [];
		xs.pushAllUnique(byKey);
		Assert.equals(2, xs.length);
		Assert.isTrue(xs.contains('x') && xs.contains('y'));
	}

	@:pin('control')
	@:killer('M-UTIL-PUSH-ALL-UNIQUE-REPEAT')
	public function testAReferenceTypeIsComparedByIdentity(): Void {
		final a: Array<Int> = [1];
		final b: Array<Int> = [1];
		final xs: Array<Array<Int>> = [];
		xs.pushAllUnique([a, a, b]);
		Assert.equals(2, xs.length);
		Assert.isTrue(xs[0] == a && xs[1] == b);
	}

}
