package unit.dev;

import dev.ScrubGuard;
import dev.ScrubRow;
import devkit.Cmd.cmd;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The slice gate's `scrub` row scans from the merge-base with main, never from a recorded base, and refuses a recorded base
 * that main does not contain: a commit under such a base is on no history main has, so a scan from the base never reads it.
 */
@:nullSafety(Strict)
final class ScrubRowStaleBaseTest extends Test {

	private static final HOME: String = ['', 'Users', 'alice'].join('/');

	@:pin('control')
	@:killer('M-SCRUB-RANGE-FROM-HEAD')
	public function testACommitUnderAStaleBaseIsInTheScannedRange(): Void {
		staleCopy((repo, stale, root) -> {
			final fromBase: Array<String> = ScrubGuard.scanRange('$stale..HEAD', [], repo);
			Assert.equals(0, fromBase.length, 'a range from the stale base never reads the commit under it');
			final fromMergeBase: Array<String> = ScrubGuard.scanRange('${ScrubRow.rangeStart(repo)}..HEAD', [], repo);
			Assert.isTrue(fromMergeBase.length > 0, 'the merge-base range reads it');
			Assert.equals(root, ScrubRow.rangeStart(repo));
		});
	}

	@:pin('control')
	@:killer('M-SCRUB-STALE-BASE-ACCEPTED')
	public function testABaseMainDoesNotContainIsRefusedWithTheRebaseThatFixesIt(): Void {
		staleCopy((repo, stale, root) -> {
			final refusal: Null<String> = ScrubRow.staleBase(repo, stale);
			Assert.notNull(refusal);
			Assert.stringContains('git rebase --onto main ${stale.substr(0, 9)}', refusal ?? '');
			Assert.isNull(ScrubRow.staleBase(repo, root));
		});
	}

	/** A repository whose `main` was rewritten after `stale` was cut from it: HEAD sits on `stale`, `root` is the last shared commit. */
	private static function staleCopy(body: (repo: String, stale: String, root: String) -> Void): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			commit(repo, 'a.txt', 'root\n', 'root');
			final root: String = head(repo);
			git(repo, ['checkout', '-q', '-b', 'stale']);
			commit(repo, 'h.txt', 'see $HOME/x\n', 'stale copy');
			final stale: String = head(repo);
			git(repo, ['checkout', '-q', 'main']);
			commit(repo, 'b.txt', 'main\n', 'main moved');
			git(repo, ['checkout', '-q', '-b', 'work', stale]);
			commit(repo, 'c.txt', 'slice\n', 'slice');
			body(repo, stale, root);
		});
	}


	private static function commit(repo: String, file: String, content: String, message: String): Void {
		File.saveContent('$repo/$file', content);
		git(repo, ['add', '.']);
		git(repo, ['commit', '-q', '-m', message]);
	}

	private static function head(repo: String): String {
		return cmd('git -C $repo rev-parse HEAD').run().out.trim();
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=gate -c user.email=gate@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}
