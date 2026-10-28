package unit.dev;

import dev.Land;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.io.Path;
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

	public function testAQuietLandingRunsTheQuickBattery(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0 });
		Assert.equals(0, run.status);
		Assert.same([['--quick']], run.flags);
		Assert.isTrue(run.output.indexOf('battery quick') >= 0, run.output);
	}

	@:pin('control')
	@:killer('M-LAND-DIVERGENCE-PATH-STAYS-QUICK')
	public function testAPathWhereShardsDivergeRunsTheFullBattery(): Void {
		final run: Landing = landing(() -> Passed, 'test/testkit/Extra.hx', { full: false, landed: 0 });
		Assert.equals(0, run.status);
		Assert.same([[]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: touches test/testkit/Extra.hx') >= 0, run.output);
	}

	@:pin('control')
	@:killer('M-LAND-TENTH-LANDING-STAYS-QUICK')
	public function testTheTenthLandingRunsTheFullBattery(): Void {
		final ninth: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 8 });
		Assert.same([['--quick']], ninth.flags);
		final tenth: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 9 });
		Assert.same([[]], tenth.flags);
		Assert.isTrue(tenth.output.indexOf('battery full: landing 10') >= 0, tenth.output);
	}

	public function testAskedForFullTheBatteryIsFullWhateverTheMergeBrings(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: true, landed: 0 });
		Assert.same([[]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: --full') >= 0, run.output);
	}

	public function testEveryPathWhereShardsAndTheMonolithCanDivergeAsksForFull(): Void {
		for (path in [
			'test/testkit/FixtureCompileCache.hx',
			'tools/src/dev/Shard.hx',
			'src/anyparse/query/ShardPlan.hx',
			'src/anyparse/query/SharedParseTier.hx',
			'src/anyparse/query/FormatConfigDiscovery.hx',
			'src/anyparse/grammar/haxe/HaxeQueryPlugin.hx',
			'src/anyparse/macro/QueryWalkerCodegen.hx',
			'src/anyparse/runtime/Parser.hx',
			'src/anyparse/query/cli/TestTranscript.hx',
			'test/RunTests.hx',
			'tools/battery.sh'
		]) Assert.notNull(Land.fullReason(['docs/a.md', path], 1, false, Land.FULL_EVERY), path);
		for (path in [
			'docs/testing.md',
			'src/anyparse/query/Linter.hx',
			'test/unit/query/ShardPlanTest.hx',
			'tools/src/dev/Land.hx'
		]) Assert.isNull(Land.fullReason([path], 1, false, Land.FULL_EVERY), path);
	}

	public function testPathsGitCannotSayAskForFull(): Void {
		Assert.notNull(Land.fullReason(null, 1, false, Land.FULL_EVERY));
	}

	public function testTheEveryRuleIsSwitchedOffByANonPositiveInterval(): Void {
		Assert.isNull(Land.fullReason(['docs/a.md'], 10, false, 0));
		Assert.notNull(Land.fullReason(['docs/a.md'], 10, false, 10));
	}

	public function testARedBatteryNamesItsModeInTheFailure(): Void {
		final quick: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0, fails: true });
		Assert.equals(1, quick.status);
		Assert.isTrue(quick.output.indexOf('battery quick — the battery is red') >= 0, quick.output);
		final full: Landing = landing(() -> Passed, 'test/testkit/Extra.hx', { full: false, landed: 0, fails: true });
		Assert.isTrue(full.output.indexOf('battery full: touches test/testkit/Extra.hx — the battery is red') >= 0, full.output);
	}

	public function testNoBatteryCountsNoLanding(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md');
		Assert.equals(0, run.status);
		Assert.same([], run.flags);
		Assert.isFalse(run.tallied);
		Assert.isTrue(landing(() -> Passed, 'docs/note.md', { full: false, landed: 0 }).tallied);
	}

	public function testMergedPathsNobodyCanReadRunTheFullBattery(): Void {
		final run: Landing = landing(() -> Passed, 'docs/note.md', { full: false, landed: 0, unreadable: true });
		Assert.same([[]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: the merged paths are unknown') >= 0, run.output);
	}

	public function testAFileRenamedOutOfTheTestKitAsksForFull(): Void {
		final run: Landing = landing(() -> Passed, 'docs/moved.md', { full: false, landed: 0 }, 'test/testkit/Old.hx');
		Assert.same([[]], run.flags);
		Assert.isTrue(run.output.indexOf('battery full: touches test/testkit/Old.hx') >= 0, run.output);
	}

	public function testTheSnapshotDirectoryIsTheOneTheBatteryScriptDefaultsTo(): Void {
		Assert.equals('/x/cache', Land.cacheDir(name -> name == 'ANYPARSE_BLAST_CACHE' ? '/x/cache' : '/home/u'));
		Assert.equals('/home/u/anyparse-blast-cache', Land.cacheDir(name -> name == 'HOME' ? '/home/u' : null));
		Assert.isTrue(
			File.getContent('tools/battery.sh').indexOf("${ANYPARSE_BLAST_CACHE:-$HOME/anyparse-blast-cache}") >= 0,
			'the script no longer spells the default the landing counts under'
		);
	}

	/**
	 * A repository whose `side` branch adds a file, landed on `main` with `build` standing in for the compiler: the first
	 * call is the build after the merge, the second the rebuild after an abort.
	 */
	private static function landing(build: () -> Outcome, added: String = 'b.txt', ?battery: Battery, ?renameFrom: String): Landing {
		return TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			File.saveContent('$repo/a.txt', 'a\n');
			if (renameFrom != null) {
				makeDirectories(Path.directory('$repo/$renameFrom'));
				File.saveContent('$repo/$renameFrom', 'moved\n');
			}
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			git(repo, ['checkout', '-q', '-b', 'side']);
			makeDirectories(Path.directory('$repo/$added'));
			if (renameFrom == null)
				File.saveContent('$repo/$added', 'b\n');
			else
				git(repo, ['mv', renameFrom, added]);
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'side']);
			git(repo, ['checkout', '-q', 'main']);
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(logs);
			final printed: Array<String> = [];
			final flags: Array<Array<String>> = [];
			var builds: Int = 0;
			final cache: String = dir.file('cache');
			if (battery != null && battery.landed > 0) {
				makeDirectories('$cache/landings');
				File.saveContent('$cache/landings/${battery.landed}', '');
			}
			final red: Bool = battery != null && battery.fails == true;
			final unreadable: Bool = battery != null && battery.unreadable == true;
			final status: Int = Land.land({
				repo: repo,
				branch: 'side',
				logs: logs,
				message: null,
				battery: battery == null ? null : {
					allowBlast: false,
					snapshot: false,
					full: battery.full,
					leased: null,
					cache: cache,
					every: Land.FULL_EVERY
				},
				compile: (tree, log) -> ++builds == 1 ? build() : Passed,
				exec: (words, tree, log) -> {
					flags.push(words);
					return red ? Failed('the battery is red') : Passed;
				},
				merged: tree -> unreadable ? null : Land.mergedPaths(tree),
				print: line -> printed.push(line)
			});
			{
				status: status,
				output: printed.join('\n'),
				flags: flags,
				tallied: FileSystem.exists('$cache/landings'),
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

	private static function makeDirectories(path: String): Void {
		js.Syntax.code("require('fs').mkdirSync({0}, { recursive: true })", path);
	}

}

/** What a `Land.land` run over a scratch repository left behind. */
private typedef Landing = {
	var status: Int;
	var output: String;

	/** The flags of every battery the run started. */
	var flags: Array<Array<String>>;

	/** Whether the landings were counted. */
	var tallied: Bool;
	var builds: Int;
	var merging: Bool;
	var dirty: String;
	var merged: Bool;
}

/** The battery a landing asks for: whether in full, and the landings the count already holds. */
private typedef Battery = {
	var full: Bool;
	var landed: Int;

	/** Whether the script is red. */
	@:optional var fails: Bool;

	/** Whether the paths of the merge cannot be read. */
	@:optional var unreadable: Bool;
}
