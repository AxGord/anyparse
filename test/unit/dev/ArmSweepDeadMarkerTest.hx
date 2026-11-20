package unit.dev;

import dev.ArmSweep;
import sys.io.File;

/**
 * A `running` record of `dev arm-sweep status` whose process is gone, or is a program
 * that took its pid, reads as dead with its log and what restarts it, never as running.
 */
@:nullSafety(Strict)
final class ArmSweepDeadMarkerTest extends Test {

	/** A pid no process holds. */
	private static inline final GONE_PID: Int = 999999999;

	/** A commit no process command line names. */
	private static inline final OTHER_SHA: String = 'badc0de0badc0de0badc0de0badc0de0badc0de0';

	/** The commit of the records. */
	private static inline final SHA: String = 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';

	@:pin('control')
	@:killer('M-SWEEP-STATUS-DEAD-READS-RUNNING')
	public function testAMarkerWhoseProcessIsGoneIsReportedDeadNotRunning(): Void {
		final lines: String = statusOf(GONE_PID);
		Assert.stringContains('$SHA dead', lines);
		Assert.equals(-1, lines.indexOf('$SHA running'));
	}

	@:pin('control')
	@:killer('M-SWEEP-DEAD-LINE-NO-LOG')
	public function testADeadSweepIsReportedWithItsLogAndWhatRestartsIt(): Void {
		final lines: String = statusOf(GONE_PID);
		Assert.stringContains('$SHA.log', lines);
		Assert.stringContains('arm-sweep run $SHA', lines);
	}

	@:pin('control')
	@:killer('M-SWEEP-PID-REUSE-TRUSTED')
	public function testAMarkerWhoseProcessIsAnotherProgramIsReportedDead(): Void {
		Assert.stringContains('$SHA dead', statusOf(js.Node.process.pid));
	}

	@:pin('control')
	@:killer('M-SWEEP-LIVE-SWEEP-NOT-RECOGNISED')
	public function testAProcessWhoseCommandLineNamesTheSweepAndItsCommitIsTheSweep(): Void {
		final child: js.node.child_process.ChildProcess = js.node.ChildProcess.spawn(
			'node', ['-e', 'setTimeout(() => {}, 20000)', 'arm-sweep', SHA]
		);
		try {
			Assert.isTrue(ArmSweep.runs(child.pid, SHA));
			Assert.isFalse(ArmSweep.runs(child.pid, OTHER_SHA));
		} catch (exception: haxe.Exception) {
			child.kill();
			throw exception;
		}
		child.kill();
	}

	private static function statusOf(pid: Int): String {
		var lines: String = '';
		TempDir.with(dir -> {
			File.saveContent(dir.file('$SHA.running'), '${dir.file('$SHA.log')}\n');
			File.saveContent(dir.file('$SHA.pid'), '$pid\n');
			lines = ArmSweep.statusLines(dir.path).join('\n');
		});
		return lines;
	}

}
