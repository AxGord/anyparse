package unit.dev;

import unit.dev.LandSweepTest.Swept;

/**
 * A sweep branch whose tip carries a follow-on cleanup on a footprint file lands with the tip's text of every file main did not
 * change since the branch's base, and with the command's output on a file main did change.
 */
@:nullSafety(Strict)
final class LandSweepTipTest extends Test {

	private static final COMMAND: String = 'hxq lint --rule r --fix src';
	private static final SIDE: Array<{ path: String, content: String }> = [
		{ path: 'src/A.hx', content: 'GOOD a\nFOLLOW\n' },
		{ path: 'src/B.hx', content: 'GOOD b\nFOLLOW\n' }
	];

	@:pin('control')
	@:killer('M-LAND-SWEEP-TIP-NOT-KEPT')
	public function testAFootprintFileMainDidNotChangeLandsAsTheBranchTipHasIt(): Void {
		final run: Swept = LandSweepTest.landing(SIDE, [], COMMAND, LandSweepTest.sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals('GOOD a\nFOLLOW\n', run.files['src/A.hx']);
		utest.Assert.equals('GOOD b\nFOLLOW\n', run.files['src/B.hx']);
		utest.Assert.stringContains('2 kept as the tip of `batch/hxqb-S1` has them', run.output);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-TIP-OVER-MAINS-EDIT')
	public function testAFootprintFileMainChangedLandsAsTheCommandWritesIt(): Void {
		final run: Swept = LandSweepTest.landing(SIDE, [{ path: 'src/A.hx', content: 'BAD a2\n' }], COMMAND, LandSweepTest.sweeping());
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.equals('GOOD a2\n', run.files['src/A.hx'], 'main\'s line, rewritten by the command');
		utest.Assert.equals('GOOD b\nFOLLOW\n', run.files['src/B.hx'], 'main left it: the tip\'s text');
	}

}
