package unit.query;

import anyparse.query.LineDiff;
import utest.Assert;
import utest.Test;

/**
 * `LineDiff.edits`: the lines of the new text outside the common subsequence, and the old lines that
 * are gone with the new line each sat before — including the unchanged run BETWEEN two edits, which
 * is what a head-and-tail trim alone reports as changed.
 */
class LineDiffTest extends Test {

	public function testAnInsertionIsItsOwnLines(): Void {
		final edits: LineEdits = LineDiff.edits(['a', 'b', 'c'], ['a', 'x', 'y', 'b', 'c'], 100);
		Assert.same([1, 2], edits.inserted);
		Assert.equals(0, edits.deleted.length);
	}

	public function testADeletionNamesTheLineItSatBefore(): Void {
		final edits: LineEdits = LineDiff.edits(['a', 'b', 'c', 'd'], ['a', 'd'], 100);
		Assert.equals(0, edits.inserted.length);
		Assert.same([{ line: 1, before: 1 }, { line: 2, before: 1 }], edits.deleted);
	}

	public function testAReplacementIsADeletionAndAnInsertion(): Void {
		final edits: LineEdits = LineDiff.edits(['a', 'b', 'c'], ['a', 'B', 'c'], 100);
		Assert.same([1], edits.inserted);
		Assert.same([{ line: 1, before: 1 }], edits.deleted);
	}

	/**
	 * Two edits at the ends keep the run between them unchanged — the property the post-write fix
	 * needs, since that run is code nobody touched.
	 * Killed by arm `M-LINE-DIFF-HULL`.
	 */
	@:pin('control')
	@:killer('M-LINE-DIFF-HULL')
	public function testTheRunBetweenTwoEditsIsUnchanged(): Void {
		final edits: LineEdits = LineDiff.edits(['a', 'b', 'c', 'd', 'e'], ['A', 'b', 'c', 'd', 'E'], 100);
		Assert.same([0, 4], edits.inserted);
		Assert.same([{ line: 0, before: 0 }, { line: 4, before: 4 }], edits.deleted);
	}

	/** Past the edit budget the region between head and tail is reported whole: wider, never narrower. */
	public function testPastTheBudgetTheMiddleIsChangedWhole(): Void {
		final edits: LineEdits = LineDiff.edits(['a', 'b', 'c', 'd', 'e'], ['A', 'b', 'c', 'd', 'E'], 1);
		Assert.same([0, 1, 2, 3, 4], edits.inserted);
		Assert.equals(5, edits.deleted.length);
	}

	public function testIdenticalTextsChangeNothing(): Void {
		final edits: LineEdits = LineDiff.edits(['a', 'b'], ['a', 'b'], 100);
		Assert.equals(0, edits.inserted.length);
		Assert.equals(0, edits.deleted.length);
	}

}
