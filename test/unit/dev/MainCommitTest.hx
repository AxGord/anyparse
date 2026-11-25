package unit.dev;

import dev.Decision;
import dev.LandCandidate;
import dev.LandLock;
import dev.MainCommit;
import devkit.Cmd.cmd;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * A commit the parent makes on main (`dev decision --commit`, `dev main-commit`) while a land holds the `anyparse-land` lock:
 * it waits for the land, and the land's advance, which fails when main moved since it began, still passes.
 */
@:nullSafety(Strict)
final class MainCommitTest extends Test {

	@:pin('control')
	@:killer('M-MAIN-COMMIT-LOCK-SKIPPED')
	public function testADecisionCommitWaitsForTheLandThatHoldsTheLockAndLandsAfterIt(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			final candidate: LandCandidate = new LandCandidate(repo, Path.join([dir.path, 'candidate']));
			Assert.isTrue(candidate.open().match(Passed));
			File.saveContent(Path.join([candidate.tree, 'landed.txt']), 'x');
			cmd('git -c user.name=land -c user.email=land@example.com -C ${candidate.tree} add .').run().check();
			cmd('git -c user.name=land -c user.email=land@example.com -C ${candidate.tree} commit --quiet -m land').run().check();
			final landed: String = candidate.made();
			// the land holds the lock: it advances main first, then the waiter gets the lock
			final order: String = Path.join([dir.path, 'order']);
			final wfRun: String = fakeWfRun(dir, [
				'sleep 1',
				'git -C \'$repo\' merge --ff-only --quiet ${candidate.commit} && echo advanced > \'$order\' || echo refused > \'$order\''
			]);

			final status: Int = Decision.main([
				'--slice',
				'T-1',
				'--commit',
				'--wf-run',
				wfRun,
				'--repo',
				repo,
				'a decision made during a land'
			]);

			Assert.equals(0, status);
			Assert.equals('advanced\n', File.getContent(order));
			Assert.stringContains('--lock anyparse-land', File.getContent(Path.join([dir.path, 'args'])));
			Assert.same(['decision: T-1 a decision made during a land', 'land', 'base'], subjects(repo));
			Assert.equals(landed, cmd('git -C $repo rev-parse --short HEAD~1').run().out.trim());
			Assert.equals('', cmd('git -C $repo status --porcelain').run().out.trim());
			Assert.isTrue(FileSystem.exists(Path.join([dir.path, 'released'])));
		});
	}

	@:pin('control')
	@:killer('M-LAND-LOCK-NOT-WAITED')
	public function testALockNotGrantedWritesAndCommitsNothing(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			final wfRun: String = fakeWfRun(dir, ['exit ${LandLock.BUSY}']);
			final failure: Null<Exception> = refusal(() -> Decision.main([
				'--slice',
				'T-1',
				'--commit',
				'--wf-run',
				wfRun,
				'--wait',
				'3',
				'--repo',
				repo,
				'never written'
			]));
			Assert.notNull(failure);
			Assert.stringContains('holds the anyparse-land lock for more than 3 s', failure?.message ?? '');
			Assert.equals('head\n---\n', File.getContent(Path.join([repo, Decision.LEDGER])));
			Assert.same(['base'], subjects(repo));
		});
	}

	@:pin('control')
	@:killer('M-MAIN-COMMIT-DIRTY-OUTSIDE')
	public function testAnUnrelatedChangeRefusesTheCommitAndTheLockIsReleased(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			File.saveContent(Path.join([repo, 'a.txt']), 'a');
			File.saveContent(Path.join([repo, Decision.LEDGER]), 'head\n---\nedited by hand\n');
			final wfRun: String = fakeWfRun(dir, []);
			final failure: Null<Exception> = refusal(() -> MainCommit.main(['-m', 'a', '--wf-run', wfRun, '--repo', repo, 'a.txt']));
			Assert.stringContains('outside a.txt', failure?.message ?? '');
			Assert.same(['base'], subjects(repo));
			Assert.isTrue(FileSystem.exists(Path.join([dir.path, 'released'])));
		});
	}

	@:pin('control')
	@:killer('M-MAIN-COMMIT-STAGES-MORE')
	public function testACommitTakesExactlyTheNamedPaths(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			FileSystem.createDirectory(Path.join([repo, 'notes']));
			File.saveContent(Path.join([repo, 'notes', 'one.md']), '1');
			File.saveContent(Path.join([repo, 'other.txt']), 'untracked and unnamed');
			final wfRun: String = fakeWfRun(dir, []);
			final status: Int = MainCommit.main([
				'-m',
				'journal: a reading',
				'--trailer',
				'Co-Authored-By: T <t@example.com>',
				'--wf-run',
				wfRun,
				'--repo',
				repo,
				'notes'
			]);
			Assert.equals(0, status);
			Assert.equals('notes/one.md', cmd('git -C $repo show --name-only --format= HEAD').run().out.trim());
			Assert.equals(
				'journal: a reading\n\nCo-Authored-By: T <t@example.com>', cmd('git -C $repo log -1 --format=%B').run().out.trim()
			);
			Assert.equals('?? other.txt', cmd('git -C $repo status --porcelain').run().out.trim());
			Assert.isTrue(refusal(() -> MainCommit.main(['-m', 'again', '--wf-run', wfRun, '--repo', repo, 'notes'])) != null);
		});
	}

	@:pin('control')
	@:killer('M-MAIN-COMMIT-AMENDS-LANDING')
	public function testAnAmendRefusesALandingCommit(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			File.saveContent(Path.join([repo, 'x.txt']), 'x');
			git(repo, ['add', '.']);
			git(repo, ['commit', '--quiet', '-m', 'a landing', '-m', 'Slice: FMT-1']);
			File.saveContent(Path.join([repo, 'x.txt']), 'y');
			final wfRun: String = fakeWfRun(dir, []);
			final failure: Null<Exception> = refusal(() -> MainCommit.main(['--amend', '--wf-run', wfRun, '--repo', repo, 'x.txt']));
			Assert.stringContains('is a landing', failure?.message ?? '');
			Assert.same(['a landing', 'base'], subjects(repo));
		});
	}

	@:pin('control')
	@:killer('M-MAIN-COMMIT-AMENDS-PUSHED')
	public function testAnAmendRefusesAPushedCommit(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			final remote: String = Path.join([dir.path, 'remote.git']);
			cmd('git init --quiet --bare $remote').run().check();
			git(repo, ['remote', 'add', 'origin', remote]);
			git(repo, ['push', '--quiet', 'origin', 'main']);
			File.saveContent(Path.join([repo, Decision.LEDGER]), 'head\n---\nmore\n');
			final wfRun: String = fakeWfRun(dir, []);
			final failure: Null<Exception> = refusal(
				() -> MainCommit.main(['--amend', '-m', 'rewritten', '--wf-run', wfRun, '--repo', repo, Decision.LEDGER])
			);
			Assert.stringContains('is pushed', failure?.message ?? '');
			Assert.same(['base'], subjects(repo));
		});
	}

	public function testAnAmendOfAnUnpushedCommitReplacesIt(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			File.saveContent(Path.join([repo, 'x.txt']), 'x');
			git(repo, ['add', '.']);
			git(repo, ['commit', '--quiet', '-m', 'docs: first']);
			File.saveContent(Path.join([repo, 'x.txt']), 'xy');
			final wfRun: String = fakeWfRun(dir, []);
			Assert.equals(0, MainCommit.main(['--amend', '-m', 'docs: second', '--wf-run', wfRun, '--repo', repo, 'x.txt']));
			Assert.same(['docs: second', 'base'], subjects(repo));
			Assert.equals('xy', cmd('git -C $repo show HEAD:x.txt').run().out);
		});
	}

	@:pin('control')
	@:killer('M-MAIN-COMMIT-UNLOCKED-LOCKS')
	public function testUnlockedCommitsWithoutAskingForTheLock(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			File.saveContent(Path.join([repo, 'a.txt']), 'a');
			final wfRun: String = fakeWfRun(dir, []);
			Assert.equals(0, MainCommit.main(['-m', 'x', '--unlocked', '--wf-run', wfRun, '--repo', repo, 'a.txt']));
			Assert.same(['x', 'base'], subjects(repo));
			Assert.isFalse(FileSystem.exists(Path.join([dir.path, 'args'])));
		});
	}

	@:pin('control')
	@:killer('M-MAIN-COMMIT-DETACHED')
	public function testADetachedHeadRefusesTheCommitAndTheLockIsReleased(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			git(repo, ['checkout', '--quiet', '--detach']);
			File.saveContent(Path.join([repo, 'a.txt']), 'a');
			final wfRun: String = fakeWfRun(dir, []);
			final failure: Null<Exception> = refusal(() -> MainCommit.main(['-m', 'x', '--wf-run', wfRun, '--repo', repo, 'a.txt']));
			Assert.stringContains('HEAD is detached', failure?.message ?? '');
			Assert.same(['base'], subjects(repo));
			Assert.isTrue(FileSystem.exists(Path.join([dir.path, 'released'])));
		});
	}

	@:pin('control')
	@:killer('M-MAIN-COMMIT-PATH-OUTSIDE')
	public function testAPathOutsideTheTreeRefusesTheCommit(): Void {
		TempDir.with(dir -> {
			final repo: String = fixture(dir);
			final wfRun: String = fakeWfRun(dir, []);
			for (path in ['../x', Path.join([dir.path, 'x']), '']) {
				final failure: Null<Exception> = refusal(() -> MainCommit.main(['-m', 'x', '--wf-run', wfRun, '--repo', repo, path]));
				Assert.stringContains('is not a path inside the tree', failure?.message ?? '');
			}
			Assert.same(['base'], subjects(repo));
		});
	}

	@:pin('control')
	@:killer('M-LAND-LOCK-VERSION-LEXICAL')
	public function testTheNewestInstalledWfRunIsFoundByNumericVersion(): Void {
		TempDir.with(dir -> {
			final cache: String = Path.join([dir.path, '.claude', 'plugins', 'cache']);
			final old: String = installed(cache, 'old-market', '0.1.6');
			final newest: String = installed(cache, 'market', '0.1.11');
			Assert.equals(newest, LandLock.locate(null, dir.path));
			Assert.equals(newest, LandLock.locate('/no/such/root', dir.path));
			final root: String = Path.join([dir.path, 'root']);
			FileSystem.createDirectory(Path.join([root, 'scripts']));
			File.saveContent(Path.join([root, 'scripts', 'wf-run']), '');
			Assert.equals(Path.join([root, 'scripts', 'wf-run']), LandLock.locate(root, dir.path));
			Assert.notEquals(old, LandLock.locate(null, dir.path));
			Assert.isNull(LandLock.locate(null, Path.join([dir.path, 'empty'])));
		});
	}

	/** A scratch main checkout holding the ledger in one commit, `base`. */
	private static function fixture(dir: TempDir): String {
		final repo: String = Path.join([dir.path, 'main']);
		FileSystem.createDirectory(Path.join([repo, 'docs']));
		git(repo, ['init', '--quiet', '--initial-branch', 'main']);
		File.saveContent(Path.join([repo, Decision.LEDGER]), 'head\n---\n');
		git(repo, ['add', '.']);
		git(repo, ['commit', '--quiet', '-m', 'base']);
		return repo;
	}

	/**
	 * A `wf-run` that records its arguments, runs `held` while it holds the lock (a landing's work), then runs the command and
	 * notes the release.
	 */
	private static function fakeWfRun(dir: TempDir, held: Array<String>): String {
		final file: String = Path.join([dir.path, 'wf-run']);
		File.saveContent(file, ['#!/bin/sh', 'echo "$@" > \'${dir.path}/args\'']
			.concat(held)
			.concat([
				'while [ "$1" != "--" ]; do shift; done',
				'shift',
				'"$@"',
				'echo released > \'${dir.path}/released\''
			])
			.join('\n')
		+ '\n');
		cmd('chmod +x $file').run().check();
		return file;
	}

	/** An installed workflow plugin of `version` under a scratch plugin cache; answers its `wf-run`. */
	private static function installed(cache: String, market: String, version: String): String {
		final scripts: String = Path.join([cache, market, 'workflow', version, 'scripts']);
		FileSystem.createDirectory(scripts);
		final file: String = Path.join([scripts, 'wf-run']);
		File.saveContent(file, '');
		return file;
	}

	/** What `run` threw, or null when it threw nothing. */
	private static function refusal(run: () -> Void): Null<Exception> {
		try {
			run();
			return null;
		} catch (exception: Exception) {
			return exception;
		}
	}

	private static function subjects(repo: String): Array<String> {
		return cmd('git -C $repo log --format=%s').run().lines();
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}
