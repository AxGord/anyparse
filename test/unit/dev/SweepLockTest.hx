package unit.dev;

import dev.LandSweep.Listing;
import dev.SweepLock;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/** What a stand-in queue CLI was asked to write, and what it answered. */
private typedef Edits = { final seen: Array<String>; final refusal: Null<String>; }

/**
 * `dev sweep-lock`: which touches a sweep line holds, over a scratch queue file, with stand-ins for the engine's listing, the
 * commit's files and the queue CLI. Line `A` is the sweep line: it declares `rule.hx` and sweeps `src`; the other lines are
 * whatever a test puts beside it.
 */
@:nullSafety(Strict)
final class SweepLockTest extends Test {

	private static final HEAD: String = 'tasks:\n  - id: A\n    status: running\n';
	private static final SWEEP: String = '    sweep: hxq lint --rule r --fix src\n    text: |-\n      sweep\n';

	@:pin('control')
	@:killer('M-SWEEP-LOCK-OVERLAP-WRITTEN')
	public function testAFootprintAFileOfARunningLineHoldsIsNotWritten(): Void {
		final queue: String = lineA('[ rule.hx ]') + other('B', 'running', '[ src/b.hx ]');
		final edits: Edits = { seen: [], refusal: null };
		final verdict: LockVerdict = held(queue, OnTree, Listed(['src/a.hx', 'src/b.hx']), [], edits);
		utest.Assert.same(Overlap('B', 'src/b.hx'), verdict);
		utest.Assert.equals(SweepLock.EXIT_OVERLAP, SweepLock.exitOf(verdict));
		utest.Assert.same([], edits.seen);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-DIRECTORY-HOLDS-NOTHING')
	public function testADirectoryOfARunningLineHoldsTheFilesUnderItAndNoSiblingName(): Void {
		utest.Assert.isTrue(SweepLock.holds('src/sub', 'src/sub/a.hx'));
		utest.Assert.isTrue(SweepLock.holds('src/sub/', 'src/sub/a.hx'));
		utest.Assert.isFalse(SweepLock.holds('src/sub', 'src/subtle.hx'));
		final queue: String = lineA('[ rule.hx ]') + other('B', 'running', '[ src/sub ]');
		utest.Assert.same(Overlap('B', 'src/sub/a.hx'), held(queue, OnTree, Listed(['src/sub/a.hx']), [], { seen: [], refusal: null }));
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-PENDING-HOLDS')
	public function testOnlyARunningLineHoldsFiles(): Void {
		final queue: String = lineA('[ rule.hx ]') + other('B', 'pending', '[ src/a.hx ]') + other('C', 'done', '[ src/a.hx ]');
		final edits: Edits = { seen: [], refusal: null };
		utest.Assert.same(Locked(['rule.hx', 'src/a.hx'], ['src/a.hx']), held(queue, OnTree, Listed(['src/a.hx']), [], edits));
		utest.Assert.same(['A=rule.hx,src/a.hx'], edits.seen);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-DECLARED-DROPPED')
	public function testTheDeclaredTouchesAreKeptBesideTheFootprintAndSavedOnce(): Void {
		devkit.TempDir.with(dir -> {
			final edits: Edits = { seen: [], refusal: null };
			final request: LockRequest = request(dir.path, lineA('[ rule.hx, test/RuleTest.hx ]'), OnTree);
			final verdict: LockVerdict = SweepLock.lock(request, stand(Listed(['src/a.hx']), [], edits));
			utest.Assert.same(Locked(['rule.hx', 'test/RuleTest.hx', 'src/a.hx'], ['src/a.hx']), verdict);
			utest.Assert.equals('rule.hx\ntest/RuleTest.hx\n', File.getContent(dir.file('logs/touches.orig')));
			utest.Assert.same(['A=rule.hx,test/RuleTest.hx,src/a.hx'], edits.seen);
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-RECOMPUTE-FROM-CURRENT')
	public function testARecomputeStartsFromTheDeclaredTouchesNotFromTheHeldOnes(): Void {
		devkit.TempDir.with(dir -> {
			final edits: Edits = { seen: [], refusal: null };
			lockedOnce(dir.path, Listed(['src/a.hx', 'src/old.hx']), edits);
			final again: LockRequest = request(dir.path, lineA('[ rule.hx, src/a.hx, src/old.hx ]'), OnTree);
			final verdict: LockVerdict = SweepLock.lock(again, stand(Listed(['src/a.hx', 'src/new.hx']), [], edits));
			utest.Assert.same(Locked(['rule.hx', 'src/a.hx', 'src/new.hx'], ['src/a.hx', 'src/new.hx']), verdict);
			utest.Assert.equals('A=rule.hx,src/a.hx,src/new.hx', edits.seen[1]);
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-FAILED-LISTING-READS-EMPTY')
	public function testAListingThatFailsNeverReadsAsAnEmptyOne(): Void {
		final edits: Edits = { seen: [], refusal: null };
		final verdict: LockVerdict = held(lineA('[ rule.hx ]'), OnTree, Unlisted('the engine died'), [], edits);
		utest.Assert.same(Unread('the engine died'), verdict);
		utest.Assert.equals(SweepLock.EXIT_UNREAD, SweepLock.exitOf(verdict));
		utest.Assert.same([], edits.seen);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-UNKNOWN-RULE-FAILS')
	public function testARuleTheEngineDoesNotKnowYetDefersTheLockToTheCommit(): Void {
		final edits: Edits = { seen: [], refusal: null };
		final verdict: LockVerdict = held(lineA('[ rule.hx ]'), OnTree, Unlisted('apq lint: unknown rule "r"'), [], edits);
		utest.Assert.same(Deferred('apq lint: unknown rule "r"'), verdict);
		utest.Assert.equals(SweepLock.EXIT_DEFERRED, SweepLock.exitOf(verdict));
		utest.Assert.same([], edits.seen);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-EMPTY-LISTING-LOCKS')
	public function testAnEmptyListingLeavesTheLineItsDeclaredTouchesAlone(): Void {
		final edits: Edits = { seen: [], refusal: null };
		devkit.TempDir.with(dir -> {
			lockedOnce(dir.path, Listed(['src/a.hx']), edits);
			final verdict: LockVerdict = SweepLock.lock(
				request(dir.path, lineA('[ rule.hx, src/a.hx ]'), OnTree), stand(Listed([]), [], edits)
			);
			utest.Assert.same(Barren, verdict);
			utest.Assert.equals(SweepLock.EXIT_BARREN, SweepLock.exitOf(verdict));
			utest.Assert.equals('A=rule.hx', edits.seen[1]);
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-COMMIT-MODE-LISTS')
	public function testAfterTheCommitTheFootprintIsTheFilesTheCommitChanged(): Void {
		final edits: Edits = { seen: [], refusal: null };
		final verdict: LockVerdict = held(
			lineA('[ rule.hx ]'), OnCommit, Unlisted('a listing now reads nothing'), ['rule.hx', 'src/a.hx'], edits
		);
		utest.Assert.same(Locked(['rule.hx', 'src/a.hx'], ['src/a.hx']), verdict);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-PLAIN-LINE-LOCKED')
	public function testALineWithoutASweepCommandIsLeftAlone(): Void {
		final queue: String = '$HEAD    touches: [ rule.hx ]\n    text: |-\n      plain\n';
		final edits: Edits = { seen: [], refusal: null };
		utest.Assert.same(Plain, held(queue, OnTree, Listed(['src/a.hx']), [], edits));
		utest.Assert.same([], edits.seen);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-RELEASE-KEEPS-FOOTPRINT')
	public function testReleasePutsTheDeclaredTouchesBackAndForgetsThem(): Void {
		devkit.TempDir.with(dir -> {
			final edits: Edits = { seen: [], refusal: null };
			lockedOnce(dir.path, Listed(['src/a.hx']), edits);
			final verdict: LockVerdict = SweepLock.lock(
				request(dir.path, lineA('[ rule.hx, src/a.hx ]'), Release), stand(Listed([]), [], edits)
			);
			utest.Assert.same(Released, verdict);
			utest.Assert.equals('A=rule.hx', edits.seen[1]);
			utest.Assert.isFalse(FileSystem.exists(dir.file('logs/touches.orig')));
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-REFUSAL-IGNORED')
	public function testAQueueWriteTheCliRefusesIsTold(): Void {
		final edits: Edits = { seen: [], refusal: 'no such line' };
		final verdict: LockVerdict = held(lineA('[ rule.hx ]'), OnTree, Listed(['src/a.hx']), [], edits);
		utest.Assert.same(Refused('no such line'), verdict);
		utest.Assert.equals(SweepLock.EXIT_REFUSED, SweepLock.exitOf(verdict));
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-HELD-FILES-UNCHECKED')
	public function testAFileTheLineHoldsAlreadyIsCheckedToo(): Void {
		final queue: String = lineA('[ rule.hx, src/b.hx ]') + other('B', 'running', '[ src/b.hx ]');
		final edits: Edits = { seen: [], refusal: null };
		utest.Assert.same(Overlap('B', 'src/b.hx'), held(queue, OnCommit, Listed([]), ['src/b.hx'], edits));
		utest.Assert.same([], edits.seen);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-PROBE-LISTS')
	public function testAProbeAsksOnlyWhetherTheLineSweeps(): Void {
		final edits: Edits = { seen: [], refusal: null };
		utest.Assert.same(Sweeps, held(lineA('[ rule.hx ]'), Probe, Listed(['src/a.hx']), [], edits));
		utest.Assert.equals(SweepLock.EXIT_SWEEPS, SweepLock.exitOf(Sweeps));
		utest.Assert.same([], edits.seen);
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-ARGV-RELEASE-IGNORED')
	public function testTheArgvReleaseFlagPutsTheDeclaredTouchesBack(): Void {
		TempDir.with(dir -> {
			scratch(dir, lineA('[ rule.hx, src/a.hx ]'));
			File.saveContent('${dir.path}/wt-logs/touches.orig', 'rule.hx\n');
			Assert.equals(0, SweepLock.main(argv(dir, ['--release'])));
			Assert.isTrue(File.getContent(dir.file('seen')).trim().endsWith('--edit A --set touches=rule.hx'));
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-ARGV-LOGS-NOT-BESIDE-TREE')
	public function testTheDeclaredTouchesAreKeptInTheLogsDirBesideTheTree(): Void {
		TempDir.with(dir -> {
			scratch(dir, lineA('[ rule.hx, src/a.hx ]'));
			File.saveContent('${dir.path}/wt-logs/touches.orig', 'rule.hx\n');
			Assert.equals(0, SweepLock.main(argv(dir, ['--release'])));
			Assert.isFalse(FileSystem.exists('${dir.path}/wt-logs/touches.orig'));
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-ARGV-COMMIT-IGNORED')
	public function testTheArgvCommitFlagReadsTheCommitNotTheListing(): Void {
		TempDir.with(dir -> {
			scratch(dir, lineA('[ rule.hx ]'));
			Assert.equals(SweepLock.EXIT_UNREAD, SweepLock.main(argv(dir, ['--commit'])));
			Assert.isFalse(FileSystem.exists(dir.file('listed')));
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-ARGV-PROBE-IGNORED')
	public function testTheArgvProbeFlagAsksOnlyWhetherTheLineSweeps(): Void {
		TempDir.with(dir -> {
			scratch(dir, lineA('[ rule.hx ]'));
			Assert.equals(SweepLock.EXIT_SWEEPS, SweepLock.main(argv(dir, ['--probe'])));
			Assert.isFalse(FileSystem.exists(dir.file('listed')));
			Assert.isFalse(FileSystem.exists('${dir.path}/wt-logs/touches.orig'));
			scratch(dir, '$HEAD    touches: [ rule.hx ]\n    text: |-\n      plain\n');
			Assert.equals(0, SweepLock.main(argv(dir, ['--probe'])));
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-ARGV-MODES-EXCLUSIVE')
	public function testTwoModesOfOneRunAreRefusedAsUsage(): Void {
		TempDir.with(dir -> {
			scratch(dir, lineA('[ rule.hx ]'));
			for (modes in [['--commit', '--release'], ['--probe', '--commit'], ['--probe', '--release']])
				Assert.raises(() -> SweepLock.main(argv(dir, modes)), devkit.Args.UsageError);
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-LOCK-ARGV-TREE-OPTIONAL')
	public function testARunWithoutATreeIsRefusedAsUsage(): Void {
		TempDir.with(dir -> {
			scratch(dir, '$HEAD    touches: [ rule.hx ]\n    text: |-\n      plain\n');
			final nameless: Array<String> = argv(dir, []).filter(word -> word != '--tree' && word != '${dir.path}/wt');
			Assert.raises(SweepLock.main.bind(nameless), devkit.Args.UsageError);
		});
	}

	private static function lineA(touches: String): String {
		return '$HEAD    touches: $touches\n$SWEEP';
	}

	private static function other(id: String, status: String, touches: String): String {
		return '  - id: $id\n    status: $status\n    touches: $touches\n    text: |-\n      other\n';
	}

	/**
	 * The scratch of a run through `SweepLock.main`: the queue, the tree, a queue CLI that records its arguments in `seen`, and an
	 * engine whose listing says the rule is unknown and leaves `listed` behind.
	 */
	private static function scratch(dir: TempDir, queue: String): Void {
		File.saveContent(dir.file('queue.yaml'), queue);
		for (made in ['wt', 'wt-logs', 'engine/bin']) if (!FileSystem.exists(dir.file(made))) FileSystem.createDirectory(dir.file(made));
		File.saveContent(dir.file('cli.sh'), '#!/bin/sh\necho "$$@" > ${dir.file('seen')}\n');
		Sys.command('chmod', ['+x', dir.file('cli.sh')]);
		File.saveContent(dir.file('engine/bin/hxq'), 'touch ${dir.file('listed')}\necho \'unknown rule "r"\' >&2\nexit 1\n');
	}

	private static function argv(dir: TempDir, modes: Array<String>): Array<String> {
		return [
			'A',
			'--tree',
			dir.file('wt'),
			'--repo',
			dir.path,
			'--queue',
			dir.file('queue.yaml'),
			'--queue-cli',
			dir.file('cli.sh'),
			'--engine',
			dir.file('engine')
		].concat(modes);
	}

	private static function request(root: String, queue: String, mode: LockMode): LockRequest {
		File.saveContent('$root/queue.yaml', queue);
		return {
			queue: '$root/queue.yaml',
			id: 'A',
			tree: '$root/tree',
			engine: '$root/tree',
			logs: '$root/logs',
			mode: mode
		};
	}

	private static function stand(listing: Listing, changed: Array<String>, edits: Edits): LockTools {
		return {
			listing: (_, _, _) -> listing,
			changed: _ -> changed,
			edit: (id, touches) -> {
				edits.seen.push('$id=${touches.join(',')}');
				edits.refusal;
			}
		};
	}

	private static function held(queue: String, mode: LockMode, listing: Listing, changed: Array<String>, edits: Edits): LockVerdict {
		return devkit.TempDir.with(dir -> SweepLock.lock(request(dir.path, queue, mode), stand(listing, changed, edits)));
	}

	private static function lockedOnce(root: String, listing: Listing, edits: Edits): Void {
		utest.Assert.isTrue(SweepLock.lock(request(root, lineA('[ rule.hx ]'), OnTree), stand(listing, [], edits)).match(Locked(_, _)));
	}

}
