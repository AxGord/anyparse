package unit.ds;

import anyparse.ds.InOrder;

/** `InOrder.kept`: the positions of a run that keeps its order, the heaviest one, the first of equals. */
final class InOrderTest extends Test {

	public function testASortedSequenceKeepsEverything(): Void {
		Assert.same([true, true, true], InOrder.kept([0, 1, 2]));
		Assert.same([], InOrder.kept([]));
	}

	public function testAMovedElementIsTheOneOutsideTheRun(): Void {
		Assert.same([false, true, true], InOrder.kept([2, 0, 1]));
		Assert.same([true, true, false], InOrder.kept([0, 1, -1]));
	}

	public function testOfEqualRunsTheFirstIsKept(): Void {
		Assert.same([true, false, true], InOrder.kept([1, 0, 2]));
	}

	public function testAWeightChoosesTheHeavierRun(): Void {
		final weights: Array<Int> = [1, 10, 1];
		Assert.same([false, true, true], InOrder.kept([1, 0, 2], k -> weights[k]));
	}

}
