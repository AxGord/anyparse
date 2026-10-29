package unit.dev;

import dev.TrapFixSweep;
import utest.Assert;
import utest.Test;

/** `dev trap-fix-sweep`'s verdict of one probe, and which verdicts fail the sweep. */
@:nullSafety(Strict)
final class TrapFixSweepTest extends Test {

	@:pin('control')
	@:killer('M-SWEEP-FIX-RESULT-IGNORED')
	public function testAFailedEngineRunIsAnErrorThatFailsTheSweep(): Void {
		Assert.equals('ERROR', TrapFixSweep.verdictOf(true, false, false, false), 'a lint --fix that did not exit 0');
		Assert.isTrue(TrapFixSweep.fails('ERROR'), 'it fails the sweep');
	}

	public function testEachVerdictAndWhetherItFails(): Void {
		Assert.same(['SKIPPED', 'BROKE', 'CHANGED', 'SAME'], [
			TrapFixSweep.verdictOf(false, false, false, false),
			TrapFixSweep.verdictOf(true, true, false, false),
			TrapFixSweep.verdictOf(true, true, true, false),
			TrapFixSweep.verdictOf(true, true, true, true)
		]);
		Assert.same([false, true, true, false], [for (v in ['SKIPPED', 'BROKE', 'CHANGED', 'SAME']) TrapFixSweep.fails(v)]);
	}

	public function testTheEditCountIsReadOffTheFixTranscript(): Void {
		Assert.same(['3', '?'], [
			TrapFixSweep.editsOf('apq lint --fix: 3 edit(s) in 1 file(s) over 2 pass(es)\n'),
			TrapFixSweep.editsOf('apq lint: no argument names a file of a known language\n')
		]);
	}

}
