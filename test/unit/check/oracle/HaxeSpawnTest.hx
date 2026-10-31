package unit.check.oracle;

import anyparse.check.oracle.HaxeSpawn;

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
		final driver: Dynamic = js.node.ChildProcess.spawn(
			js.Node.process.execPath, HaxeSpawn.driverArgs(1, ROOMY, false, { result: '', jobs: '$dir/jobs.json' }), { stdio: 'ignore' }
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

	/**
	 * A driver whose `apq` parent is SIGKILLed — no handler runs in a killed process — notices its parent is gone and
	 * takes its jobs' groups down within about a second. The parent is a child process of this binary
	 * (`testkit.TestChild`), killed while its job's own child runs.
	 */
	@:pin('control')
	@:killer('M-DRIVER-OUTLIVES-ITS-PARENT')
	public function testAKilledParentTakesItsJobsWithIt(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('spawnparent', []);
		sys.io.File.saveContent(
			'$dir/jobs.json', haxe.Json.stringify([{ args: [], cwd: dir, shell: 'sleep 30 & echo $! > child.txt; wait' }])
		);
		final env: Dynamic = js.Syntax.code('Object.assign({}, process.env)');
		env.APQ_TEST_CHILD = 'spawn';
		env.APQ_TEST_CHILD_INPUT = '$dir/jobs.json';
		final parent: Dynamic = js.node.ChildProcess.spawn(
			js.Node.process.execPath,
			[js.Syntax.code('process.argv[1]')],
			{ env: env, stdio: 'ignore' }
		);
		final child: Null<Int> = waitForPid('$dir/child.txt');
		Assert.notNull(child, 'the job started its child');
		parent.kill('SIGKILL');
		var gone: Bool = false;
		for (_ in 0...30) {
			if (!signalable(child)) {
				gone = true;
				break;
			}
			js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100)');
		}
		if (!gone && child != null) js.Syntax.code('process.kill({0}, "SIGKILL")', child);
		Assert.isTrue(gone, 'the job\'s child died once its apq was gone');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/**
	 * The process driver gets its jobs through a FILE, its stdin is the null device. Node's `spawnSync` on macOS can lose
	 * the writability wakeup of an `input` pipe — the stdin socket drained, the caller asleep in `kevent` with bytes still
	 * to write — and a driver blocked reading that stdin never starts a job: the `runAll` hang. The job asks what its
	 * parent, the driver, holds as fd 0.
	 */
	@:pin('control')
	@:killer('M-DRIVER-READS-STDIN')
	public function testTheDriverReadsItsJobsFromNoPipe(): Void {
		#if nodejs
		if (js.Node.process.platform == 'win32') {
			Assert.pass('no lsof or /proc to ask on Windows');
			return;
		}
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			{
				args: [],
				cwd: null,
				shell: 'if [ -e /proc/$$PPID/fd/0 ]; then readlink /proc/$$PPID/fd/0; else lsof -a -p $$PPID -d 0 -F n; fi'
			}
		], ROOMY, 1);
		Assert.equals(0, runs[0].status, 'the probe ran: ${runs[0].failure} ${runs[0].err}');
		Assert.isTrue(runs[0].out.indexOf('/dev/null') >= 0, 'the driver\'s stdin is the null device, not a pipe: ${runs[0].out}');
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/**
	 * A driver that stops doing its work is killed once its bound is spent, and every job answers that it produced no
	 * verdict: nothing waits on a wedged driver forever. Run in a child process (`testkit.TestChild.wedge`), so a driver
	 * the bound fails to end fails this test instead of hanging the suite.
	 */
	@:pin('control')
	@:killer('M-DRIVER-UNBOUNDED')
	public function testAWedgedDriverIsKilledAtItsBound(): Void {
		#if nodejs
		if (js.Node.process.platform == 'win32') {
			Assert.pass('no SIGSTOP on Windows');
			return;
		}
		final dir: String = CliFixture.writeDir('spawnwedge', []);
		final runs: Null<Array<HaxeRun>> = testkit.TestChild.wedge('bounded-run', dir, 1500);
		Assert.notNull(runs, 'runAll answered while its driver was stopped');
		if (runs != null) {
			Assert.isNull(runs[0].status, 'no verdict');
			Assert.isTrue(runs[0].failure.indexOf('did not answer within 1500 ms') >= 0, 'and the failure says why: ${runs[0].failure}');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/**
	 * The bound grows by a round of the longest job for every `parallel` jobs, a job naming no `timeout` counting as a long
	 * one: three jobs of one second each cost two more seconds run one at a time than all at once, and a job without a
	 * timeout outweighs any short one.
	 */
	@:pin('control')
	@:killer('M-DRIVER-BOUND-IGNORES-ROUNDS')
	public function testTheDriverBoundScalesWithTheJobs(): Void {
		final short: Array<SpawnJob> = [for (_ in 0...3) { args: [], cwd: null, timeout: 1000 }];
		Assert.equals(2000, HaxeSpawn.driverBound(short, 1) - HaxeSpawn.driverBound(short, 3));
		final open: Array<SpawnJob> = [{ args: [], cwd: null }];
		Assert.isTrue(HaxeSpawn.driverBound(open, 1) > HaxeSpawn.driverBound([{ args: [], cwd: null, timeout: 60000 }], 1));
	}

	/**
	 * A killed job may run its command in a process group of its own, as a pool lease wrapper does: the driver ends it with a
	 * SIGTERM the wrapper forwards, never a bare SIGKILL that leaves it no handler, so the command dies with the driver.
	 */
	@:pin('control')
	@:killer('M-DRIVER-KILLS-WITHOUT-GRACE')
	public function testAKilledJobForwardsItsEndToItsOwnGroup(): Void {
		#if nodejs
		final forwarder: String = 'const cp = require("child_process");const c = cp.spawn("sleep", ["30"], {'
			+ ' detached: true, stdio: "ignore" });require("fs").writeFileSync("child.txt", String(c.pid));'
			+ 'for (const s of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(s, () => { try { process.kill(-c.pid, s); } catch (err) {} });'
			+ 'c.on("exit", code => process.exit(code === null ? 1 : code));';
		final shell: String = 'exec \'${js.Node.process.execPath}\' forward.js';
		final outlived: Null<Float> = childOutlivesDriver('spawnforward', [{ name: 'forward.js', source: forwarder }], shell, 5000);
		Assert.notNull(outlived, 'the command the job started in its own group died with the driver');
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/**
	 * A job that ignores the SIGTERM is SIGKILLed once the grace is out, its whole group with it: the driver waits for it
	 * rather than exiting with the group alive.
	 */
	@:pin('control')
	@:killer('M-DRIVER-NO-HARD-KILL')
	public function testAJobIgnoringTheTermIsKilledAfterTheGrace(): Void {
		#if nodejs
		final outlived: Null<Float> = childOutlivesDriver('spawnstubborn', [], "trap '' TERM; sleep 30 & echo $! > child.txt; wait", 5000);
		Assert.notNull(outlived, 'the job\'s child died once the grace was out');
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/**
	 * Start the process driver on the one shell job `shell` in a fresh directory holding `files`, wait for the job to write
	 * its child's pid to `child.txt`, SIGTERM the driver, and answer how long the child outlived the signal in ms; null when
	 * it never started or was alive `waitMs` later, when it is SIGKILLed here.
	 */
	private static function childOutlivesDriver(
		prefix: String, files: Array<{ name: String, source: String }>, shell: String, waitMs: Int
	): Null<Float> {
		#if nodejs
		final dir: String = CliFixture.writeDir(prefix, files);
		sys.io.File.saveContent('$dir/jobs.json', haxe.Json.stringify([{ args: [], cwd: dir, shell: shell }]));
		final driver: js.node.child_process.ChildProcess = js.node.ChildProcess.spawn(
			js.Node.process.execPath, HaxeSpawn.driverArgs(1, ROOMY, false, { result: '', jobs: '$dir/jobs.json' }), { stdio: 'ignore' }
		);
		final child: Null<Int> = waitForPid('$dir/child.txt');
		if (child == null) {
			driver.kill('SIGKILL');
			CliFixture.removeDir(dir);
			return null;
		}
		final signalled: Float = Date.now().getTime();
		driver.kill('SIGTERM');
		var outlived: Null<Float> = null;
		while (outlived == null && Date.now().getTime() - signalled < waitMs) {
			if (signalable(child))
				js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100)');
			else
				outlived = Date.now().getTime() - signalled;
		}
		if (outlived == null) js.Syntax.code('process.kill({0}, "SIGKILL")', child);
		CliFixture.removeDir(dir);
		return outlived;
		#else
		return null;
		#end
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
		} catch (exception: haxe.Exception) {
			false;
		};
	}
	#end

}
