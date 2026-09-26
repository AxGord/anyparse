package unit.check;

import anyparse.check.HaxeSpawn;
import anyparse.check.PendingRuns;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `PendingRuns`: a batch started with `HaxeSpawn.startAll` runs while the caller goes on, and `cancel` ends it.
 *
 * Both fixtures are shell jobs that sleep, so what they assert is a matter of WHEN: the margins are a whole second,
 * far past the scheduling noise of a loaded machine and far short of the sleep a foreground batch would still owe.
 */
@:nullSafety(Strict)
final class PendingRunsTest extends Test {

	/** Megabytes a job may print — far more than an `echo` needs. */
	private static inline final BUFFER: Int = 1024 * 1024;

	/** The batch ran while the caller slept, so the answer is waiting when asked for, with the job's output. */
	@:pin('control')
	@:killer('M-PENDING-RUNS-IN-FOREGROUND')
	public function testABatchRunsWhileTheCallerWorks(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('pendingruns', []);
		final pending: PendingRuns = HaxeSpawn.startAll([{ args: [], cwd: dir, shell: 'sleep 2 && echo done' }], BUFFER, 1);
		Sys.sleep(3);
		final asked: Float = Sys.time();
		final runs: Array<HaxeRun> = pending.await();
		Assert.isTrue(Sys.time() - asked < 1, 'the answer was ready: the job ran while the caller slept');
		Assert.equals(0, runs[0].status);
		Assert.equals('done', StringTools.trim(runs[0].out));
		Assert.same(runs, pending.await(), 'asked again, the same answer');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('no asynchronous process API on this target');
		#end
	}

	/**
	 * The batch talks to its driver inside a directory of its own, readable by this user alone, and the jobs file is gone
	 * as soon as the driver read it — a run killed mid-batch leaves no job list behind — and the directory with the answer.
	 */
	@:pin('control')
	@:killer('M-PENDING-JOBS-FILE-KEPT')
	public function testTheBatchFilesArePrivateAndShortLived(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('pendingfiles', []);
		final before: Array<String> = pendingDirs();
		final pending: PendingRuns = HaxeSpawn.startAll([{ args: [], cwd: dir, shell: 'sleep 1' }], BUFFER, 1);
		Sys.sleep(0.5);
		final made: Array<String> = [for (d in pendingDirs()) if (!before.contains(d)) d];
		Assert.equals(1, made.length, 'one directory for the batch');
		final own: String = haxe.io.Path.join([anyparse.core.TempScratch.root(), made[0] ?? '']);
		final mode: Int = (js.Syntax.code('require("fs").statSync({0}).mode', own): Int) & 511;
		Assert.equals(448, mode, 'owner-only permissions');
		Assert.isFalse(sys.FileSystem.exists('$own/jobs.json'), 'the driver deleted the jobs once read');
		pending.await();
		Assert.isFalse(sys.FileSystem.exists(own), 'and the directory is gone with the answer');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('no asynchronous process API on this target');
		#end
	}

	/** A cancelled batch ends the job it started: the job's last step never runs, and the answer is a cancellation. */
	@:pin('control')
	@:killer('M-PENDING-CANCEL-LEAVES-JOBS')
	public function testACancelledBatchEndsItsJobs(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('pendingcancel', []);
		final pending: PendingRuns = HaxeSpawn.startAll([{ args: [], cwd: dir, shell: 'sleep 1.5 && touch marker' }], BUFFER, 1);
		Sys.sleep(0.5);
		pending.cancel();
		Sys.sleep(2.5);
		Assert.isFalse(sys.FileSystem.exists('$dir/marker'), 'the job was ended before its last step');
		Assert.isTrue(pending.await()[0].cancelled == true, 'and the batch answers it as cancelled');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('no asynchronous process API on this target');
		#end
	}

	#if nodejs
	/** The batch directories under the scratch root now. */
	private static function pendingDirs(): Array<String> {
		return [
			for (entry in sys.FileSystem.readDirectory(anyparse.core.TempScratch.root())) if (StringTools.startsWith(entry, 'apq-pending-'))
				entry
		];
	}
	#end

}
