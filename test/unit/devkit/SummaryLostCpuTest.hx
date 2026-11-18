package unit.devkit;

import anyparse.proc.SpawnJob;
import devkit.CpuMeter;
import devkit.Summary;
import sys.io.File;

/**
 * A step in which a process started under the cpu meter never reported its usage (time(1) killed with its child by a limit)
 * has no cpu reading: it is unmetered, never a reading of zero.
 */
@:nullSafety(Strict)
final class SummaryLostCpuTest extends Test {

	@:pin('control')
	@:killer('M-CPUMETER-SINCE-LOST')
	public function testAStepThatLostAProcessReadsNoCpu(): Void {
		TempDir.with(dir -> {
			CpuMeter.begin(dir.file('usage'), '/usr/bin/time');
			final summary: Summary = new Summary();
			Assert.isTrue(summary.time('lint', () -> {
				final job: SpawnJob = CpuMeter.wrap({ cmd: 'tool', args: [] });
				File.saveContent(job.args[2], '');
				return Passed;
			}).match(Passed));
			CpuMeter.end();
			Assert.isNull(summary.steps()[0].cpu);
		});
	}

}
