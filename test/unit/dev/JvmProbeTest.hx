package unit.dev;

import dev.JvmProbe;
import devkit.Result;
import utest.Assert;
import utest.Test;

/**
 * `dev jvm-portability`'s verdict over a probe run: the gate line holds only when every file was written and none threw,
 * and a run with no gate line, or one that failed outright, is no pass either.
 */
@:nullSafety(Strict)
final class JvmProbeTest extends Test {

	public function testTheGateLineDecides(): Void {
		Assert.isNull(JvmProbe.refusal(run(0, 'gate: files=702 wrote=702 threw=0 lintdiff=1+0-\ncensus @ x: checks=1\n')));
		Assert.notNull(JvmProbe.refusal(run(0, 'gate: files=702 wrote=702 threw=1 lintdiff=1+0-\n')), 'a throw');
		Assert.notNull(JvmProbe.refusal(run(0, 'gate: files=702 wrote=701 threw=0 lintdiff=1+0-\n')), 'a file not written');
		Assert.notNull(JvmProbe.refusal(run(0, 'census only\n')), 'no gate line');
		Assert.notNull(JvmProbe.refusal(run(1, 'gate: files=1 wrote=1 threw=0 lintdiff=1+0-\n')), 'the probe failed');
	}

	private static function run(status: Int, out: String): Result {
		return new Result('java -jar bin/jvm-portability.jar', {
			status: status,
			out: out,
			err: '',
			failure: '',
			overflowed: false
		});
	}

}
