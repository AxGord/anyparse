package unit.dev;

import dev.JvmProbe;
import devkit.Args;
import devkit.Result;
import utest.Assert;
import utest.Test;

/**
 * `dev jvm-portability`'s verdict over a probe run: the gate line holds only when every file was written and none threw,
 * and a run with no gate line, or one that failed outright, is no pass either. `--cpp` swaps the `--jvm` build and run
 * for the hxcpp pair and keeps the paths.
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

	@:pin('control')
	@:killer('M-JVM-PROBE-CPP-IGNORED')
	public function testCppPicksTheHxcppPair(): Void {
		final cpp: ProbeCommands = JvmProbe.commands(new Args(['--cpp']));
		Assert.equals('hxcpp', cpp.target);
		Assert.equals('haxe tools/hxcpp-portability.hxml', cpp.build.argv.join(' '));
		Assert.equals('bin/hxcpp-portability/JvmPortability', cpp.run.argv.join(' '));
		final jvm: ProbeCommands = JvmProbe.commands(new Args([]));
		Assert.equals('haxe tools/jvm-portability.hxml', jvm.build.argv.join(' '));
		Assert.equals('java -jar bin/jvm-portability.jar', jvm.run.argv.join(' '));
	}

	@:pin('control')
	@:killer('M-JVM-PROBE-CPP-DROPS-PATHS')
	public function testCppKeepsThePaths(): Void {
		Assert.equals('bin/hxcpp-portability/JvmPortability a.hx', JvmProbe.commands(new Args(['--cpp', 'a.hx'])).run.argv.join(' '));
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
