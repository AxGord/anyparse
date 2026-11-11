package unit.devkit;

import anyparse.proc.ProcessSpawn;
import anyparse.proc.SpawnJob;
import devkit.Command;
import devkit.Lease;
import devkit.Result;
import devkit.TempDir;
import haxe.io.Path;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A leased command's `timeout` counts from its lease's grant, not from the start of the `wf-run` that waits for it: a wait
 * longer than the bound is a queue, not a wedge, while a command that runs past its bound once granted is still killed.
 */
@:nullSafety(Strict)
final class LeaseWaitTest extends Test {

	/** The bound each command here names: shorter than the lease wait, far longer than the quick command. */
	private static inline final BOUND: Int = 2000;

	/** A `wf-run` that skips its own options, waits three seconds for its grant, then runs the command after `--`. */
	private static final SLOW_WF_RUN: String =
		'#!/bin/sh\nwhile [ "$$1" != "--" ]; do shift; done\nshift\nsleep 3\nWF_THREADS=1 exec "$$@"\n';

	@:pin('control')
	@:killer('M-LEASE-CLOCK-FROM-SPAWN')
	public function testALeaseWaitLongerThanTheBoundDoesNotKill(): Void {
		TempDir.with(dir -> {
			final command: Command = Command.of(['node', '-e', 'process.stdout.write("ran")']).timeout(BOUND);
			final run: Result = Lease.take(Own(slowWfRun(dir), 1), command, { min: 1, max: 1 }, 'quick').run();
			Assert.equals(0, run.status, run.failure);
			Assert.equals('ran', run.out);
		});
	}

	/** A batch holding a leased job has no wall bound counted from the driver's spawn: the lease wait is not the driver's. */
	@:pin('control')
	@:killer('M-LEASE-DRIVER-BOUND')
	public function testABatchHoldingALeasedJobIsNotBoundFromTheSpawn(): Void {
		final plain: SpawnJob = { args: [] };
		final leased: SpawnJob = { args: [], leased: true };
		Assert.isTrue(ProcessSpawn.driverBound([plain], 1) < 2147483647);
		Assert.equals(2147483647, ProcessSpawn.driverBound([plain, leased], 1));
	}

	/** The command ends by itself well after its bound, so a run whose bound was never armed answers a clean exit, never a hang. */
	@:pin('control')
	@:killer('M-DRIVER-NO-TIMEOUT')
	public function testARunningCommandPastItsBoundIsStillKilled(): Void {
		TempDir.with(dir -> {
			final command: Command = Command.of(['node', '-e', 'setTimeout(() => {}, 20000)']).timeout(BOUND);
			final run: Result = Lease.take(Own(slowWfRun(dir), 1), command, { min: 1, max: 1 }, 'hang').run();
			Assert.isNull(run.status);
			Assert.isTrue(run.failure.endsWith('timed out after $BOUND ms'), run.failure);
		});
	}

	/** The grant file ends with the mark: the leased command does not inherit the variable naming it. */
	@:pin('guard')
	public function testALeasedCommandDoesNotInheritTheGrantVariable(): Void {
		TempDir.with(dir -> {
			final command: Command = Command.of(['node', '-e', 'process.stdout.write(String(process.env.APQ_LEASE_GRANT))']);
			final run: Result = Lease.take(Own(slowWfRun(dir), 1), command, { min: 1, max: 1 }, 'env').run();
			Assert.equals(0, run.status, run.failure);
			Assert.equals('undefined', run.out);
		});
	}

	/** A grant file that cannot be written never stops the command the mark runs. */
	@:pin('guard')
	public function testAnUnwritableGrantFileDoesNotStopTheCommand(): Void {
		TempDir.with(dir -> {
			final run: Result = Command.of([
				'sh',
				'-c',
				Command.GRANT_MARK,
				'sh',
				'node',
				'-e',
				'process.stdout.write("ran")'
			])
				.env('APQ_LEASE_GRANT', dir.file('missing/g'))
				.run();
			Assert.equals(0, run.status, run.err);
			Assert.equals('ran', run.out);
		});
	}

	/** A leased job always goes through the process driver, the one place its grant is watched. */
	@:pin('guard')
	public function testALeasedJobNeedsTheDriver(): Void {
		Assert.isTrue(ProcessSpawn.needsDriver({ args: [], leased: true }));
		Assert.isFalse(ProcessSpawn.needsDriver({ args: [] }));
	}

	/** The slow `wf-run` written into `dir`. */
	private static function slowWfRun(dir: TempDir): String {
		final wfRun: String = Path.join([dir.path, 'wf-run']);
		sys.io.File.saveContent(wfRun, SLOW_WF_RUN);
		js.Syntax.code("require('fs').chmodSync({0}, 0o755)", wfRun);
		return wfRun;
	}

}
