package unit.dev;

import dev.MergeArms;
import utest.Assert;
import utest.Test;

/**
 * `dev merge-arms`, the merge driver of `mutation-arms.json`, over synthetic registries: the record-keyed three-way merge
 * a line merge cannot do for JSON, and the collisions it hands back to git.
 */
@:nullSafety(Strict)
final class MergeArmsTest extends Test {

	@:pin('control')
	@:killer('M-MERGE-ARMS-APPEND-ORDER')
	public function testAppendsOnBothSidesKeepOursFirst(): Void {
		Assert.equals(file([arm('A', '1'), arm('X', '1'), arm('Y', '1')]), merged([arm('A', '1')], [arm('A', '1'), arm('X', '1')], [
			arm('A', '1'),
			arm('Y', '1')
		]));
	}

	@:pin('control')
	@:killer('M-MERGE-ARMS-THEIRS-LOST')
	public function testAChangeOnOneSideWinsOverTheOthersSilence(): Void {
		final base: Array<String> = [arm('A', '1'), arm('B', '1')];
		Assert.equals(file([arm('A', '2'), arm('B', '2')]), merged(base, [arm('A', '2'), arm('B', '1')], [arm('A', '1'), arm('B', '2')]));
	}

	public function testARemovalOnOneSideWinsOverTheOthersSilence(): Void {
		final base: Array<String> = [arm('A', '1'), arm('B', '1')];
		Assert.equals(file([arm('A', '1'), arm('Y', '1')]), merged(base, [arm('A', '1')], [arm('A', '1'), arm('B', '1'), arm('Y', '1')]));
	}

	public function testTheSameAppendOnBothSidesIsOneRecord(): Void {
		final both: Array<String> = [arm('A', '1'), arm('X', '1')];
		Assert.equals(file(both), merged([arm('A', '1')], both, both));
	}

	public function testTwoDifferentEditsOfOneArmCollide(): Void {
		Assert.raises(() -> merged([arm('A', '1')], [arm('A', '2')], [arm('A', '3')]), MergeConflict);
	}

	public function testAnEditAgainstARemovalCollides(): Void {
		Assert.raises(() -> merged([arm('A', '1'), arm('B', '1')], [arm('A', '1')], [arm('A', '1'), arm('B', '2')]), MergeConflict);
	}

	public function testANameDeclaredTwiceIsRefused(): Void {
		Assert.raises(() -> MergeArms.parse(file([arm('A', '1'), arm('A', '2')])), MergeConflict);
	}

	private static function merged(base: Array<String>, ours: Array<String>, theirs: Array<String>): String {
		return MergeArms.merge(file(base), file(ours), file(theirs));
	}

	/** A registry holding `records`, laid out as the real one is. */
	private static function file(records: Array<String>): String {
		return '{\n\t"$$comment": ["the registry"],\n\t"arms": [\n\t\t${records.join(',\n\t\t')}\n\t]\n}\n';
	}

	private static function arm(name: String, note: String): String {
		return '{\n\t\t\t"name": "$name",\n\t\t\t"note": "$note"\n\t\t}';
	}

}
