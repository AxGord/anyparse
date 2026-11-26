package unit.dev;

import dev.BranchWatch;
import dev.MutationSlot;
import devkit.Cmd.cmd;
import haxe.Exception;
import sys.FileSystem;
import sys.io.File;

/**
 * A track whose build or suite never ends gets a verdict within its limit, and it signs of life at each phase, so the gate that
 * watches the arms branch for silence sees a bounded wait.
 */
@:nullSafety(Strict)
final class MutationSlotHungBuildTest extends Test {

	/** A build the compiler never finishes ends at the build limit, as a build verdict. */
	@:pin('control')
	@:killer('M-MUTSLOT-COLD-BUILD-UNBOUNDED')
	public function testAHungColdBuildEndsAsABuildVerdictWithinTheBuildLimit(): Void {
		TempDir.with(dir -> {
			final started: Float = Sys.time();
			final workroot: String = trackWith(dir, 'sleep 20\nexit 1', ['APQ_MUTATION_BUILD_TIMEOUT' => '1']);
			Assert.isTrue(Sys.time() - started < 10, 'the cold build ran to its own end');
			Assert.equals('BUILD-FAIL', MutationSlot.readVerdict(workroot, 'H')[0]);
		});
	}

	/** A track says it is building before its build starts: a gate sees the phase begin, not only the track end. */
	@:pin('control')
	@:killer('M-MUTSLOT-COLD-BUILD-NO-SIGN')
	public function testATrackSignsOfLifeBeforeItsBuild(): Void {
		TempDir.with(dir -> {
			final seen: String = dir.file('bin/seen');
			final workroot: String = trackWith(
				dir, 'cat "$$APQ_ARMS_PROGRESS" > ${seen}\nexit 1', ['APQ_ARMS_PROGRESS' => dir.file('progress')]
			);
			Assert.equals('arms: H building cold', File.getContent(seen));
			Assert.equals('BUILD-FAIL', MutationSlot.readVerdict(workroot, 'H')[0]);
		});
	}

	/** A suite that keeps writing and never ends is cut at the suite limit and read as a hung run, which the stall watch never cuts. */
	@:pin('control')
	@:killer('M-MUTSLOT-SUITE-UNBOUNDED')
	public function testASuiteThatKeepsWritingEndsAsAHungVerdictAtTheSuiteLimit(): Void {
		TempDir.with(dir -> {
			final runner: String = 'setInterval(() => process.stdout.write(\'x\'), 50); setTimeout(() => process.exit(0), 15000);';
			final started: Float = Sys.time();
			final workroot: String = trackWith(
				dir, 'for a; do out=$$a; done\necho "$runner" > "$$out"', ['APQ_MUTATION_SUITE_TIMEOUT' => '1']
			);
			Assert.isTrue(Sys.time() - started < 10, 'the suite ran to its own end');
			final verdict: Array<String> = MutationSlot.readVerdict(workroot, 'H');
			Assert.equals('MISMATCH', verdict[0]);
			Assert.stringContains('hung', verdict[1]);
		});
	}

	/**
	 * One suite run is bounded below the limit the gate watches the arms
	 * branch by, so a track's silence ends before the gate calls it stalled.
	 */
	@:pin('control')
	@:killer('M-MUTSLOT-SUITE-LIMIT-ABOVE-WATCH')
	public function testASuiteRunEndsBeforeTheArmsBranchIsCalledStalled(): Void {
		final saved: String = Sys.getEnv(BranchWatch.IDLE_VAR) ?? '';
		Sys.putEnv(BranchWatch.IDLE_VAR, '');
		final watch: Int = BranchWatch.idleOf(['arms']);
		Sys.putEnv(BranchWatch.IDLE_VAR, saved);
		Assert.isTrue(MutationSlot.suiteTimeoutMs() + 300 * 1000 <= watch, 'a suite run leaves the gate five minutes of slack');
	}

	/** The verdict of a build that was killed at its limit says so, since the killed compiler printed no error for a reader to find. */
	@:pin('control')
	@:killer('M-MUTSLOT-BUILD-CUT-UNSTATED')
	public function testAKilledBuildIsNamedByItsTimeoutInTheVerdict(): Void {
		TempDir.with(dir -> {
			final workroot: String = trackWith(dir, 'sleep 20\nexit 1', ['APQ_MUTATION_BUILD_TIMEOUT' => '1']);
			Assert.stringContains('build timed out after 1s', MutationSlot.readVerdict(workroot, 'H')[1]);
		});
	}

	/**
	 * Run track `H` in a slot of `dir` whose `haxe` is the shell script `haxe`, under the environment `env`; the workroot. The slot's
	 * tree is a git tree holding `a.txt`, which the track's patch changes.
	 */
	private static function trackWith(dir: TempDir, haxe: String, env: Map<String, String>): String {
		final bin: String = dir.file('bin');
		FileSystem.createDirectory(bin);
		File.saveContent('$bin/haxe', '#!/bin/sh\n$haxe\n');
		cmd('chmod +x $bin/haxe').check();
		final workroot: String = dir.file('work');
		SlotWorkroot.oneTrack(workroot, 'H');
		final saved: Map<String, String> = ['PATH' => Sys.getEnv('PATH') ?? ''];
		for (name in env.keys()) saved[name] = Sys.getEnv(name) ?? '';
		Sys.putEnv('PATH', '$bin:${saved['PATH']}');
		for (name => value in env) Sys.putEnv(name, value);
		try {
			MutationSlot.run(1, workroot);
		} catch (exception: Exception) {
			for (name => value in saved) Sys.putEnv(name, value);
			throw exception;
		}
		for (name => value in saved) Sys.putEnv(name, value);
		return workroot;
	}

}
