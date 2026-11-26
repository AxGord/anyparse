package unit.dev;

import dev.Battery;
import dev.Land;
import dev.LandFormat.FormatTools;
import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** What a `dev land` run left behind. */
private typedef Landing = {
	var status: Int;
	var output: String;
	var batteries: Int;
	var baseLint: Bool;
	var landed: Bool;
	var journal: Bool;
	var slices: Int;
}

/**
 * `dev land` over a main whose recent commits touch only paths no test reads (`TolerantPaths`): its base takes the snapshot
 * of an ancestor instead of a whole battery of its own, and a main that moves on during the land is followed. A commit
 * that touches anything else changes neither.
 */
@:nullSafety(Strict)
final class LandTolerantMainTest extends Test {

	private static final BRANCH: String = 'batch/hxqb-S1';

	@:pin('control')
	@:killer('M-LAND-BASE-CARRY-NEVER')
	public function testABaseBehindJournalCommitsBorrowsTheSnapshotOfAnAncestor(): Void {
		final run: Landing = land(['docs/journal/log.md', 'docs/decisions.md'], true, false);
		Assert.equals(0, run.status, run.output);
		Assert.equals(1, run.batteries, 'the landing\'s own battery runs; the base has none of its own');
		Assert.stringContains('carries the snapshot of', run.output);
		Assert.isFalse(run.output.indexOf('had no snapshot') >= 0, run.output);
		Assert.isTrue(run.baseLint, 'the lint reading of the ancestor is the base\'s');
	}

	@:pin('control')
	@:killer('M-TOLERANT-SNAPSHOT-ANY-ANCESTOR')
	public function testABaseBehindASourceCommitMakesItsOwnSnapshot(): Void {
		final run: Landing = land(['docs/journal/log.md', 'src/x.hx'], true, false);
		Assert.equals(0, run.status, run.output);
		Assert.equals(2, run.batteries, 'the base is measured by a battery of its own, then the landing is judged');
		Assert.stringContains('had no snapshot — made', run.output);
	}

	@:pin('control')
	@:killer('M-LAND-FOLLOW-NEVER')
	public function testAMainThatMovesOnByAJournalCommitDuringTheLandIsFollowedAndTheLandPasses(): Void {
		final run: Landing = land([], true, true);
		Assert.equals(0, run.status, run.output);
		Assert.stringContains('picked onto it, not judged again', run.output);
		Assert.equals(1, run.batteries);
		Assert.isTrue(run.landed, 'the slice is in main');
		Assert.isTrue(run.journal, 'what main took meanwhile is in main');
		Assert.equals(1, run.slices, 'the slice commit is on main once');
	}

	/**
	 * `dev land` of a one-file slice onto a main whose last commits touch
	 * `onMain`; `moves` has main commit a journal line while the build runs.
	 */
	private static function land(onMain: Array<String>, seeded: Bool, moves: Bool): Landing {
		return TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			File.saveContent('$repo/.gitignore', 'bin/*.out\n# $repo\n');
			File.saveContent('$repo/a.txt', 'a\n');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			final cache: String = dir.file('cache');
			if (seeded) {
				FileSystem.createDirectory(cache);
				final key: String = Battery.keyOf(repo, 'HEAD') ?? '';
				File.saveContent('$cache/$key-suite.txt', '1 2\n');
				File.saveContent('$cache/$key-anyparse.json', '{}');
			}
			git(repo, ['checkout', '-q', '-b', BRANCH]);
			File.saveContent('$repo/b.txt', 'b\n');
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'side']);
			git(repo, ['checkout', '-q', 'main']);
			for (path in onMain) {
				FileSystem.createDirectory(Path.directory('$repo/$path'));
				File.saveContent('$repo/$path', 'on main\n');
				git(repo, ['add', '.']);
				git(repo, ['commit', '-q', '-m', 'main moved']);
			}
			final logs: String = dir.file('logs');
			LandLedgerSeam.seedStale(logs);
			final printed: Array<String> = [];
			var batteries: Int = 0;
			var built: Int = 0;
			final base: String = Battery.keyOf(repo, 'HEAD') ?? '';
			final status: Int = Land.land({
				repo: repo,
				branch: BRANCH,
				logs: logs,
				message: null,
				battery: {
					allowBlast: false,
					snapshot: false,
					allow: [],
					full: false,
					leased: null,
					cache: cache,
					every: Land.FULL_EVERY
				},
				compile: (tree, log, _) -> {
					FileSystem.createDirectory('$tree/bin');
					File.saveContent('$tree/bin/engine.out', 'built\n');
					if (moves && ++built == 1) {
						FileSystem.createDirectory('$repo/docs/journal');
						File.saveContent('$repo/docs/journal/log.md', 'a reading\n');
						git(repo, ['add', '.']);
						git(repo, ['commit', '-q', '-m', 'journal: a reading']);
					}
					return Passed;
				},
				format: idle(),
				exec: (words, tree, log) -> {
					batteries++;
					LandLedgerSeam.fill(words);
					if (words.indexOf('--repo') >= 0) File.saveContent('$cache/$base-suite.txt', '1 2\n');
					return Passed;
				},
				merged: Land.mergedPaths,
				print: line -> printed.push(line)
			});
			{
				status: status,
				output: printed.join('\n'),
				batteries: batteries,
				baseLint: FileSystem.exists('$cache/$base-anyparse.json'),
				landed: FileSystem.exists('$repo/b.txt'),
				journal: FileSystem.exists('$repo/docs/journal/log.md'),
				slices: cmd('git -C $repo log --format=%s').run().lines().filter(subject -> subject == 'side').length
			};
		});
	}

	private static function idle(): FormatTools {
		return { rewrite: (tree, files) -> Passed, changes: (tree, base, files) -> '', settled: (tree, files) -> Passed };
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=land -c user.email=land@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}
