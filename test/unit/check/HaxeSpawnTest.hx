package unit.check;

import anyparse.check.HaxeSpawn;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `HaxeSpawn` — the one `haxe` child process the compiler-oracle package starts, and the
 * three OUTCOMES its callers read apart.
 *
 * They were three near-copies before, and what had drifted between them is exactly what
 * these tests pin: whether a non-zero exit is a verdict or a refusal, and whether an output
 * OVERFLOW is distinguishable from a compiler that never ran. The second one has no other
 * cover: an overflow arrives as a spawn error with a null status, so a caller that reads
 * only `status` cannot tell "the build failed and here is why" from "there is no `haxe` on
 * this machine".
 */
@:nullSafety(Strict)
final class HaxeSpawnTest extends Test {

	/** Big enough that nothing this test runs can reach it. */
	private static inline final ROOMY: Int = 8 * 1024 * 1024;

	/** A run that PRODUCED a verdict carries no `failure`, whatever it exited with. */
	public function testASuccessfulRunCarriesNoFailure(): Void {
		final run: HaxeRun = HaxeSpawn.run(['--version'], null, ROOMY);
		if (run.failure != '') {
			Assert.pass('haxe unavailable — skipped (${run.failure})');
			return;
		}
		Assert.equals(0, run.status);
		Assert.isFalse(run.overflowed);
		Assert.isTrue(run.out.length + run.err.length > 0, 'the version text reaches the caller through one of the two streams');
	}

	/**
	 * A compiler that ran and REFUSED is not a failure of the spawn: `status` carries the
	 * refusal and `failure` stays empty, which is what lets `CompilerOracle` answer `Rejected`
	 * here and `Unavailable` for a missing binary.
	 */
	public function testARejectedRunIsStillARun(): Void {
		final run: HaxeRun = HaxeSpawn.run(['--no-such-flag-zzz'], null, ROOMY);
		if (run.failure != '' && run.status == null && run.out == '' && run.err == '') {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		Assert.equals('', run.failure, 'the process ran; only its verdict was negative');
		Assert.notEquals(0, run.status);
		Assert.isFalse(run.overflowed);
	}

	/** On nodejs the working directory is honoured; the native `sys` branch has none to honour. */
	public function testHonoursCwdMatchesTheTarget(): Void {
		Assert.equals(#if nodejs true #else false #end, HaxeSpawn.honoursCwd());
	}

	#if nodejs
	/**
	 * An overflow says the compiler RAN. `status` is null either way, so without `overflowed`
	 * this is indistinguishable from a missing binary — and the two send a reader to opposite
	 * places. One byte of buffer against `haxe --version` is the smallest way to produce it.
	 */
	public function testAnOverflowIsToldApartFromAMissingBinary(): Void {
		final run: HaxeRun = HaxeSpawn.run(['--version'], null, 1);
		if (!run.overflowed && run.failure.indexOf('could not launch') != -1) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		Assert.isTrue(run.overflowed, 'got: ${run.failure}');
		Assert.isNull(run.status);
		Assert.isTrue(run.failure.indexOf('output buffer') != -1, 'and the sentence names the buffer: ${run.failure}');
	}
	#end

	/**
	 * `stopAfterFailure` ends every LATER job: a fast failure cancels a slow job declared after it (killed while running
	 * with two slots, never started with one), so a rejection does not wait for — or pay for — a compile that cannot
	 * change the verdict.
	 */
	@:pin('control')
	@:killer('M-DRIVER-NEVER-STOPS')
	public function testAFailureEndsTheJobsDeclaredAfterIt(): Void {
		#if nodejs
		final jobs: Array<SpawnJob> = [
			{ args: [], cwd: null, shell: 'exit 3' },
			{ args: [], cwd: null, shell: 'sleep 5' }
		];
		final started: Float = Date.now().getTime();
		final overlapped: Array<HaxeRun> = HaxeSpawn.runAll(jobs, ROOMY, 2, true);
		Assert.equals(3, overlapped[0].status, 'the failure is answered as it ran');
		Assert.isTrue(overlapped[1].cancelled == true && overlapped[1].unstarted != true, 'the running later job was killed');
		final sequential: Array<HaxeRun> = HaxeSpawn.runAll(jobs, ROOMY, 1, true);
		Assert.isTrue(sequential[1].unstarted == true, 'with one slot it never started');
		Assert.isTrue(Date.now().getTime() - started < 4000, 'neither run waited for the slow job');
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/**
	 * A cancelled shell job's CHILDREN die with it: the kill reaches the job's whole process group, so a build tool the
	 * shell started cannot keep writing after its job was answered. The child here writes a file two seconds in.
	 */
	@:pin('control')
	@:killer('M-DRIVER-KILLS-ONLY-THE-SHELL')
	public function testACancelledShellJobTakesItsChildrenWithIt(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('spawngroup', []);
		final jobs: Array<SpawnJob> = [
			{ args: [], cwd: null, shell: 'sleep 0.5; exit 1' },
			{ args: [], cwd: dir, shell: '(sleep 2; echo leaked > leak.txt) & wait' }
		];
		final runs: Array<HaxeRun> = HaxeSpawn.runAll(jobs, ROOMY, 2, true);
		Assert.isTrue(runs[1].cancelled == true, 'the later job was cancelled');
		js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000)');
		Assert.isFalse(sys.FileSystem.exists('$dir/leak.txt'), 'and the process it started died with it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/** A job that outlives its `timeout` is killed and answered as timed out, not waited for. */
	@:pin('control')
	@:killer('M-DRIVER-NO-TIMEOUT')
	public function testAJobPastItsTimeoutIsKilled(): Void {
		#if nodejs
		final started: Float = Date.now().getTime();
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			{
				args: [],
				cwd: null,
				shell: 'sleep 5',
				timeout: 300
			}
		], ROOMY, 1);
		Assert.isNull(runs[0].status, 'no exit status: it was killed');
		Assert.isTrue(runs[0].failure.indexOf('timed out') >= 0, 'and says so: ${runs[0].failure}');
		Assert.isTrue(Date.now().getTime() - started < 4000, 'without waiting the five seconds out');
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/**
	 * A signal to the process driver takes every running job's process group down with it: the groups are detached, so a
	 * Ctrl-C at the terminal would otherwise leave a build tool writing on. The job records its child's pid, the driver
	 * gets SIGTERM, and the child must be gone.
	 */
	@:pin('control')
	@:killer('M-DRIVER-SIGNAL-ORPHANS')
	public function testASignalledDriverTakesItsJobsWithIt(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('spawnsignal', []);
		// the jobs go in through a FILE: this test blocks its own event loop while it polls, so a piped write would never flush
		sys.io.File.saveContent(
			'$dir/jobs.json', haxe.Json.stringify([{ args: [], cwd: dir, shell: 'sleep 30 & echo $! > child.txt; wait' }])
		);
		final input: Int = js.Syntax.code("require('fs').openSync({0}, 'r')", '$dir/jobs.json');
		final driver: Dynamic = js.node.ChildProcess.spawn(
			js.Node.process.execPath, HaxeSpawn.driverArgs(1, ROOMY, false), { stdio: [input, 'ignore', 'ignore'] }
		);
		final child: Null<Int> = waitForPid('$dir/child.txt');
		Assert.notNull(child, 'the job started its child');
		driver.kill('SIGTERM');
		var gone: Bool = false;
		for (_ in 0...50) {
			if (!signalable(child)) {
				gone = true;
				break;
			}
			js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100)');
		}
		if (!gone && child != null) js.Syntax.code('process.kill({0}, "SIGKILL")', child);
		Assert.isTrue(gone, 'the job\'s child died with the driver');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	#if nodejs
	/** The pid written to `path` once it appears, polling up to five seconds. */
	private static function waitForPid(path: String): Null<Int> {
		for (_ in 0...50) {
			final text: Null<String> = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
			final pid: Null<Int> = Std.parseInt(StringTools.trim(text ?? ''));
			if (pid != null) return pid;
			js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100)');
		}
		return null;
	}

	/** Whether `pid` answers a signal-0 probe. */
	private static function signalable(pid: Null<Int>): Bool {
		return pid != null && try {
			js.Syntax.code('process.kill({0}, 0)', pid);
			true;
		} catch (exception: haxe.Exception) false;
	}
	#end

}
