package unit.dev;

import dev.Battery;
import dev.TolerantPaths;
import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The list of paths no test reads, and the two questions a landing asks
 * of it: what a main commit changed, and which snapshot a base may borrow.
 */
@:nullSafety(Strict)
final class TolerantPathsTest extends Test {

	public function testThePathsAreTheLedgerAndTheJournalDirectory(): Void {
		Assert.isTrue(TolerantPaths.covers('docs/decisions.md'));
		Assert.isTrue(TolerantPaths.covers('docs/journal/testing-log.md'));
		Assert.isTrue(TolerantPaths.covers('docs/journal/deeper/x.md'));
	}

	public function testOtherDocsAndLookalikesAreNotCovered(): Void {
		for (path in [
			'docs/strategies.md',
			'docs/',
			'CLAUDE.md',
			'docs/decisions.md.bak',
			'docs/journalist.md',
			'docs/journal',
			'src/docs/decisions.md'
		]) Assert.isFalse(TolerantPaths.covers(path), path);
	}

	public function testAChangeInsideIsOneThatNamesFilesAndEveryOneIsCovered(): Void {
		Assert.isTrue(TolerantPaths.inside(['docs/decisions.md', 'docs/journal/a.md']));
		Assert.isFalse(TolerantPaths.inside(['docs/decisions.md', 'src/A.hx']));
		Assert.isFalse(TolerantPaths.inside([]), 'a change of no file is no tolerated change');
	}

	public function testATreeDiffersOnlyInTolerantPathsOrNot(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir, ['a.txt']);
			final base: String = rev(repo, 'HEAD');
			commit(repo, 'docs/journal/log.md');
			final journal: String = rev(repo, 'HEAD');
			commit(repo, 'src/x.hx');
			Assert.isTrue(TolerantPaths.onlyBetween(repo, base, journal));
			Assert.isFalse(TolerantPaths.onlyBetween(repo, base, rev(repo, 'HEAD')));
			Assert.isFalse(TolerantPaths.onlyBetween(repo, base, base), 'no file changed');
			Assert.isTrue(TolerantPaths.ancestor(repo, base, journal));
			Assert.isFalse(TolerantPaths.ancestor(repo, journal, base));
		});
	}

	@:pin('control')
	@:killer('M-TOLERANT-SNAPSHOT-ANY-ANCESTOR')
	public function testASnapshotBehindASourceChangeIsNotBorrowed(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir, ['a.txt']);
			final cache: String = dir.file('cache');
			seed(repo, cache, 'HEAD');
			commit(repo, 'src/x.hx');
			commit(repo, 'docs/journal/log.md');
			Assert.isNull(TolerantPaths.snapshotBefore(repo, rev(repo, 'HEAD'), cache));
		});
	}

	@:pin('control')
	@:killer('M-TOLERANT-SNAPSHOT-NEVER')
	public function testASnapshotBehindTolerantCommitsOnlyIsBorrowed(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir, ['a.txt']);
			final cache: String = dir.file('cache');
			seed(repo, cache, 'HEAD');
			final key: String = Battery.keyOf(repo, 'HEAD') ?? '';
			commit(repo, 'docs/journal/log.md');
			commit(repo, 'docs/decisions.md');
			Assert.equals(key, TolerantPaths.snapshotBefore(repo, rev(repo, 'HEAD'), cache));
		});
	}

	public function testTheNearestSnapshotIsTheOneBorrowed(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir, ['a.txt']);
			final cache: String = dir.file('cache');
			seed(repo, cache, 'HEAD');
			commit(repo, 'docs/journal/log.md');
			seed(repo, cache, 'HEAD');
			final near: String = Battery.keyOf(repo, 'HEAD') ?? '';
			commit(repo, 'docs/decisions.md');
			Assert.equals(near, TolerantPaths.snapshotBefore(repo, rev(repo, 'HEAD'), cache));
		});
	}

	public function testAHeadWithNoSnapshotBehindItGetsNone(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir, ['a.txt']);
			commit(repo, 'docs/journal/log.md');
			Assert.isNull(TolerantPaths.snapshotBefore(repo, rev(repo, 'HEAD'), dir.file('cache')));
		});
	}

	/** The snapshot of `at` in `cache`: the suite counts that mark it and a lint reading. */
	private static function seed(repo: String, cache: String, at: String): Void {
		final key: String = Battery.keyOf(repo, at) ?? '';
		FileSystem.createDirectory(cache);
		File.saveContent(Path.join([cache, '$key-suite.txt']), '1 2\n');
		File.saveContent(Path.join([cache, '$key-anyparse.json']), '{}');
	}

	private static function scaffold(dir: TempDir, files: Array<String>): String {
		final repo: String = dir.file('repo');
		FileSystem.createDirectory(repo);
		git(repo, ['init', '--quiet', '--initial-branch', 'main']);
		for (file in files) File.saveContent('$repo/$file', 'a\n');
		git(repo, ['add', '.']);
		git(repo, ['commit', '--quiet', '-m', 'base']);
		return repo;
	}

	/** A commit that changes `path`, its content never the same twice. */
	private static function commit(repo: String, path: String): Void {
		FileSystem.createDirectory(Path.directory('$repo/$path'));
		final sha: String = rev(repo, 'HEAD');
		File.saveContent('$repo/$path', '$sha\n');
		git(repo, ['add', '.']);
		git(repo, ['commit', '--quiet', '-m', 'change $path']);
	}

	private static function rev(repo: String, name: String): String {
		return cmd('git -C $repo rev-parse $name').run().out.trim();
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}
