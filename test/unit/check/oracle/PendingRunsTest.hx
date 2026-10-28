package unit.check.oracle;

import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.PendingRuns;

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

	/** Seconds a job is given to start and write its pid: bounds a hang, the wait ends once the pid is there. */
	private static inline final START_S: Float = 90;

	/** Seconds the tethered job sleeps: past any stall of the fixture, so only the tether or the cleanup ends it. */
	private static inline final TETHERED_S: Int = 600;

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

	/**
	 * A TETHERED job dies with the driver that started it, however the driver went: a SIGKILL of the driver alone is what
	 * a SIGKILL of the process group `apq` and its driver share does to the driver, and leaves it no handler to run. The
	 * job's own process group is not the driver's, so nothing but the tether can end it.
	 */
	@:pin('control')
	@:killer('M-TETHER-IGNORES-EOF')
	@:access(anyparse.check.oracle.PendingRuns)
	public function testATetheredJobDiesWithItsDriver(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('pendingtether', []);
		final pending: PendingRuns = HaxeSpawn.startAll([
			{
				args: [],
				cwd: dir,
				shell: 'echo $$$$ > job.pid && exec sleep $TETHERED_S',
				tethered: true
			}
		], BUFFER, 1);
		final job: Null<Int> = awaitPid('$dir/job.pid');
		final driver: Null<Int> = pending._pid;
		Assert.notNull(job, 'the job started');
		Assert.notNull(driver, 'the batch has a driver');
		if (job != null && driver != null) {
			Assert.isTrue(ProcessProbe.alive(job), 'the job runs while its driver does');
			Assert.equals(0, ProcessProbe.outlivingKilledDriver(driver, [job]).length, 'the job outlived its driver');
		}
		pending.cancel();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('no asynchronous process API on this target');
		#end
	}

	/**
	 * A background driver that stops doing its work is killed once its bound is spent, and `await` answers every job as
	 * one that produced no verdict instead of polling a stopped process forever. Run in a child process
	 * (`testkit.TestChild.wedge`), so a bound that fails fails this test instead of hanging the suite.
	 */
	@:pin('control')
	@:killer('M-PENDING-UNBOUNDED')
	public function testAWedgedBackgroundDriverIsKilledAtItsBound(): Void {
		#if nodejs
		if (js.Node.process.platform == 'win32') {
			Assert.pass('no SIGSTOP on Windows');
			return;
		}
		final dir: String = CliFixture.writeDir('pendingwedge', []);
		final runs: Null<Array<HaxeRun>> = testkit.TestChild.wedge('bounded-pending', dir, 1500);
		Assert.notNull(runs, 'await answered while the driver was stopped');
		if (runs != null) {
			Assert.isNull(runs[0].status, 'no verdict');
			Assert.isTrue(runs[0].failure.indexOf('did not answer within 1500 ms') >= 0, 'and the failure says why: ${runs[0].failure}');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('no asynchronous process API on this target');
		#end
	}

	#if nodejs
	/** The pid written to `path`, waiting for the file to appear and fill; null when it never does. */
	private static function awaitPid(path: String): Null<Int> {
		final until: Float = Sys.time() + START_S;
		while (true) {
			final text: String = sys.FileSystem.exists(path) ? StringTools.trim(sys.io.File.getContent(path)) : '';
			final pid: Null<Int> = Std.parseInt(text);
			// the look after the last sleep is taken even past the bound: a stalled fixture must not miss a pid already there
			if (pid != null || Sys.time() >= until) return pid;
			Sys.sleep(0.05);
		}
	}

	/** The batch directories under the scratch root now. */
	private static function pendingDirs(): Array<String> {
		return [
			for (entry in sys.FileSystem.readDirectory(anyparse.core.TempScratch.root())) if (StringTools.startsWith(entry, 'apq-pending-'))
				entry
		];
	}
	#end

}
