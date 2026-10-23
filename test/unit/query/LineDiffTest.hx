package unit.query;

import anyparse.query.LineDiff;
import haxe.Exception;

/**
 * `LineDiff.edits`: the lines of the new text outside the common subsequence, and the old lines that
 * are gone with the new line each sat before — including the unchanged run BETWEEN two edits, which
 * is what a head-and-tail trim alone reports as changed.
 */
class LineDiffTest extends Test {

	public function testAnInsertionIsItsOwnLines(): Void {
		final edits: LineEdits = edited(['a', 'b', 'c'], ['a', 'x', 'y', 'b', 'c']);
		Assert.same([1, 2], edits.inserted);
		Assert.equals(0, edits.deleted.length);
	}

	public function testADeletionNamesTheLineItSatBefore(): Void {
		final edits: LineEdits = edited(['a', 'b', 'c', 'd'], ['a', 'd']);
		Assert.equals(0, edits.inserted.length);
		Assert.same([{ line: 1, before: 1 }, { line: 2, before: 1 }], edits.deleted);
	}

	public function testAReplacementIsADeletionAndAnInsertion(): Void {
		final edits: LineEdits = edited(['a', 'b', 'c'], ['a', 'B', 'c']);
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
		final edits: Null<LineEdits> = LineDiff.edits(['a', 'b', 'c', 'd', 'e'], ['A', 'b', 'c', 'd', 'E'], 100);
		Assert.notNull(edits);
		if (edits == null) return;
		Assert.same([0, 4], edits.inserted);
		Assert.same([{ line: 0, before: 0 }, { line: 4, before: 4 }], edits.deleted);
	}

	/** Past the edit budget there is no answer: a caller narrowing by the changed lines must not act on their hull. */
	public function testPastTheBudgetThereIsNoAnswer(): Void {
		Assert.isNull(LineDiff.edits(['a', 'b', 'c', 'd', 'e'], ['A', 'b', 'c', 'd', 'E'], 1));
	}

	public function testIdenticalTextsChangeNothing(): Void {
		final edits: LineEdits = edited(['a', 'b'], ['a', 'b']);
		Assert.equals(0, edits.inserted.length);
		Assert.equals(0, edits.deleted.length);
	}

	/**
	 * A net change of an ODD number of lines with the new text the longer one is still found within the
	 * budget, not given up on — the shape a comment-only write that adds one line in one place and edits
	 * a line in another produces.
	 * Killed by arm `M-LINE-DIFF-PARITY`.
	 */
	@:pin('control')
	@:killer('M-LINE-DIFF-PARITY')
	public function testAnOddNetInsertionIsFoundWithinTheBudget(): Void {
		final edits: Null<LineEdits> = LineDiff.edits(['a', 'b', 'c'], ['a', 'x', 'b', 'C'], 100);
		Assert.notNull(edits);
		if (edits == null) return;
		Assert.same([1, 3], edits.inserted);
		Assert.equals(1, edits.deleted.length);
		Assert.equals(2, edits.deleted[0].line);
	}

	/** Over seeded random pairs the script is MINIMAL: its length is what the longest common subsequence leaves. */
	public function testTheScriptIsMinimalOverRandomPairs(): Void {
		var seed: Int = 12345;
		inline function next(bound: Int): Int {
			seed = (seed * 1103515245 + 12345) & 0x7fffffff;
			return seed % bound;
		}
		for (_ in 0...400) {
			final old: Array<String> = [for (_ in 0...next(9)) String.fromCharCode('a'.code + next(3))];
			final now: Array<String> = [for (_ in 0...next(9)) String.fromCharCode('a'.code + next(3))];
			final edits: Null<LineEdits> = LineDiff.edits(old, now, 100);
			Assert.notNull(edits, '$old -> $now');
			if (edits == null) return;
			final common: Int = commonLength(old, now);
			Assert.equals(old.length - common, edits.deleted.length, '$old -> $now');
			Assert.equals(now.length - common, edits.inserted.length, '$old -> $now');
		}
	}

	/** The longest common subsequence's length, by the textbook table. */
	private static function commonLength(a: Array<String>, b: Array<String>): Int {
		final table: Array<Array<Int>> = [for (_ in 0...a.length + 1) [for (_ in 0...b.length + 1) 0]];
		for (i => x in a) for (j => y in b) {
			final skipOld: Int = table[i][j + 1];
			final skipNew: Int = table[i + 1][j];
			table[i + 1][j + 1] = if (x == y)
				table[i][j] + 1
			else if (skipOld > skipNew)
				skipOld
			else
				skipNew;
		}
		return table[a.length][b.length];
	}

	/** The script for `old -> now` within a budget no fixture here comes near, failing the test when there is none. */
	private static function edited(old: Array<String>, now: Array<String>): LineEdits {
		final found: Null<LineEdits> = LineDiff.edits(old, now, 100);
		if (found == null) throw new Exception('no script within the budget for $old -> $now');
		return found;
	}

}
