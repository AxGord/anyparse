package unit.dev;

import anyparse.query.ExitCode;
import anyparse.query.format.json.LintFindingJson;
import dev.LandSweep;
import unit.dev.LandSweepTest.Swept;

/** A site the sweep's fix declines on purpose, which the branch tip carries too, stays as it is: the landing is not residue. */
@:nullSafety(Strict)
final class LandSweepDeclinedTest extends Test {

	@:pin('control')
	@:killer('M-LAND-SWEEP-DECLINED-NOT-CARRIED')
	public function testASiteTheFixDeclinesAndTheBranchTipCarriesTooLands(): Void {
		final side: Array<{ path: String, content: String }> = [
			{ path: 'src/A.hx', content: 'GOOD a\n' },
			{ path: 'src/B.hx', content: 'BAD b2\n' }
		];
		final run: Swept = LandSweepTest.landing(side, [], 'hxq lint --rule r --fix src', LandSweepTest.sweeping('src/B.hx'));
		utest.Assert.equals(0, run.status, run.output);
		utest.Assert.isTrue(run.moved, run.output);
		utest.Assert.equals(
			'BAD b2\n', run.files['src/B.hx'], 'main did not change the file: the tip\'s text, which holds the declined site'
		);
		utest.Assert.stringContains('1 finding(s) the tip of `batch/hxqb-S1` carries too left as they are, first src/B.hx', run.output);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-EVERYTHING-CARRIED')
	public function testAFindingTheTipLacksIsStillResidueBesideACarriedOne(): Void {
		final side: Array<{ path: String, content: String }> = [
			{ path: 'src/A.hx', content: 'GOOD a\n' },
			{ path: 'src/B.hx', content: 'BAD b2\n' }
		];
		final parallel: Array<{ path: String, content: String }> = [{ path: 'src/D.hx', content: 'BAD ${LandSweepTest.DECLINED} d\n' }];
		final run: Swept = LandSweepTest.landing(side, parallel, 'hxq lint --rule r --fix src', LandSweepTest.sweeping('src/B.hx'));
		utest.Assert.equals((ExitCode.EXIT_RESIDUE: Int), run.status, run.output);
		utest.Assert.isFalse(run.moved);
	}

	@:pin('control')
	@:killer('M-LAND-SWEEP-SPLIT-NOT-SPENT')
	public function testTheTipExcusesAsManyFindingsAsItCarries(): Void {
		final one: LintFindingJson = LandSweepTest.finding('src/B.hx', 'BAD');
		final other: LintFindingJson = LandSweepTest.finding('src/B.hx', 'BAD elsewhere');
		final standing: Standing = LandSweep.split([one, one, other], [one]);
		utest.Assert.equals(1, standing.carried.length);
		utest.Assert.equals(2, standing.fresh.length);
		utest.Assert.same([other], standing.fresh.filter(record -> record.message != 'BAD'));
	}

}
