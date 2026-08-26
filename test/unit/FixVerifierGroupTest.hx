package unit;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.FixVerifier;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * Unit coverage of `FixVerifier.unitsOf` — the partition the bisect walks now that a
 * check can declare edits inseparable (`GroupedFix`). Deterministic, no compiler.
 *
 * The all-ungrouped case is the BACKWARD-COMPATIBILITY pin: an all-null group array is
 * exactly what a non-`GroupedFix` check yields, and it must still produce one singleton
 * unit per edit, so that bisect stays byte-for-byte the one that shipped. The other two
 * pin what grouping adds — interleaved ids coalesce in FIRST-APPEARANCE order, and one
 * group spanning everything collapses to a single unit, which is the `n < 2` shape that
 * sends `verifyEntry` straight to a whole-file revert. The internal is reached through
 * `@:access`.
 */
@:access(anyparse.check.FixVerifier)
@:nullSafety(Strict)
final class FixVerifierGroupTest extends Test {

	public function testUngroupedEditsStayOneUnitEach(): Void {
		Assert.same([[0], [1], [2]], FixVerifier.unitsOf(editsGrouped([null, null, null])));
	}

	public function testInterleavedGroupsCoalesceInFirstAppearanceOrder(): Void {
		Assert.same([[0], [1, 3], [2], [4]], FixVerifier.unitsOf(editsGrouped([null, 0, null, 0, 1])));
	}

	public function testOneGroupSpanningEverythingIsASingleUnit(): Void {
		Assert.same([[0, 1, 2]], FixVerifier.unitsOf(editsGrouped([7, 7, 7])));
	}

	/** One edit per entry of `groups`, carrying that id; the spans differ but the partition never reads them. */
	private static function editsGrouped(groups: Array<Null<Int>>): Array<GroupedEdit> {
		return [
			for (i in 0...groups.length) { span: new Span(i, i + 1), text: '', group: groups[i] }
		];
	}

}
