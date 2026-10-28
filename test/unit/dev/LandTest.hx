package unit.dev;

import dev.Land;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev land` over a scratch repository: a step after the merge that does not pass — one that threw as much as one that
 * failed — takes the merge back, and the battery's flags follow the lease.
 */
@:nullSafety(Strict)
final class LandTest extends Test {

	@:pin('control')
	@:killer('M-LAND-NOT-RUN-KEEPS-MERGE')
	public function testABuildThatThrewTakesTheMergeBack(): Void {
		final run: Landing = landing(() -> throw 'the compiler could not be started');
		Assert.equals(1, run.status);
		Assert.isTrue(run.output.indexOf('not run') >= 0);
		Assert.equals(2, run.builds);
		Assert.isFalse(run.merging);
		Assert.equals('', run.dirty);
		Assert.isFalse(run.merged);
	}

	public function testABuildThatFailedTakesTheMergeBack(): Void {
		final run: Landing = landing(() -> Failed('no good'));
		Assert.equals(1, run.status);
		Assert.isFalse(run.merging);
		Assert.equals('', run.dirty);
		Assert.isFalse(run.merged);
	}

	public function testAGreenBuildLeavesTheMergeCommitted(): Void {
		final run: Landing = landing(() -> Passed);
		Assert.equals(0, run.status);
		Assert.equals(1, run.builds);
		Assert.isTrue(run.merged);
	}

	public function testTheBatteryIsQuickUnlessAskedFull(): Void {
		Assert.same(['--quick'], Land.batteryFlags(false, false, false, null));
		Assert.same([], Land.batteryFlags(false, false, true, null));
		Assert.same(['--allow-blast', '--snapshot', '--quick'], Land.batteryFlags(true, true, false, null));
	}

	public function testTheSuiteTakesTheShardsALeaseLeavesBesideTheLightBranches(): Void {
		Assert.same(['--quick', '-n', '4'], Land.batteryFlags(false, false, false, 8));
		Assert.same(['--quick', '-n', '1'], Land.batteryFlags(false, false, false, 2));
	}

	/**
	 * A repository whose `side` branch adds a file, landed on `main` with `build` standing in for the compiler: the first
	 * call is the build after the merge, the second the rebuild after an abort.
	 */
	private static function landing(build: () -> Outcome): Landing {
		return TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			File.saveContent('$repo/a.txt', 'a\n');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			git(repo, ['checkout', '-q', '-b', 'side']);
			File.saveContent('$repo/b.txt', 'b\n');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'side']);
			git(repo, ['checkout', '-q', 'main']);
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(logs);
			final printed: Array<String> = [];
			var builds: Int = 0;
			final status: Int = Land.land({
				repo: repo,
				branch: 'side',
				logs: logs,
				message: null,
				battery: null,
				compile: (tree, log) -> ++builds == 1 ? build() : Passed,
				print: line -> printed.push(line)
			});
			{
				status: status,
				output: printed.join('\n'),
				builds: builds,
				merging: cmd('git -C $repo rev-parse -q --verify MERGE_HEAD').run().ok,
				dirty: cmd('git -C $repo status --porcelain').run().out.trim(),
				merged: FileSystem.exists('$repo/b.txt')
			};
		});
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=land -c user.email=land@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}

/** What a `Land.land` run over a scratch repository left behind. */
private typedef Landing = {
	var status: Int;
	var output: String;
	var builds: Int;
	var merging: Bool;
	var dirty: String;
	var merged: Bool;
}
