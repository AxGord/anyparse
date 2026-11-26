package unit.dev;

import dev.FrozenSnapshot;
import dev.FrozenTree;
import dev.GateTree;
import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** `dev.FrozenSnapshot`: the copy of a downstream tree's HEAD that the slice gate's `frozen` row reads instead of the live checkout. */
@:nullSafety(Strict)
final class FrozenSnapshotTest extends Test {

	/**
	 * The snapshot is the committed HEAD: the live tree's uncommitted
	 * edits and untracked files are not in it, and it is not the live tree.
	 */
	@:pin('control')
	@:killer('M-FROZEN-SNAPSHOT-IS-LIVE')
	public function testASnapshotHoldsTheCommittedHeadAndNothingOfTheLiveEdits(): Void {
		TempDir.with(dir -> {
			final live: String = LiveGitTree.make(dir);
			File.saveContent(Path.join([live, 'a.hx']), 'class A { var edited: Int; }\n');
			File.saveContent(Path.join([live, 'untracked.hx']), 'class U {}\n');
			final snapshot: String = FrozenSnapshot.take(dir.file('cache'), live);
			Assert.notEquals(live, snapshot);
			Assert.equals('class A {}\n', File.getContent(Path.join([snapshot, 'a.hx'])));
			Assert.isFalse(FileSystem.exists(Path.join([snapshot, 'untracked.hx'])));
			Assert.isFalse(FileSystem.exists(Path.join([snapshot, '.git'])));
		});
	}

	/** Every gate of one commit reads one snapshot: an edit of the live tree leaves the record as it was. */
	@:pin('control')
	@:killer('M-FROZEN-SNAPSHOT-KEY-MOVES')
	public function testAnEditOfTheLiveTreeLeavesTheRecordOfItsCommitAsItWas(): Void {
		TempDir.with(dir -> {
			final live: String = LiveGitTree.make(dir);
			final cache: String = dir.file('cache');
			final before: FrozenTree = FrozenSnapshot.record(cache, live);
			File.saveContent(Path.join([live, 'a.hx']), 'class A { var edited: Int; }\n');
			Assert.same(before, FrozenSnapshot.record(cache, live));
			Assert.equals(before.digest, FrozenSnapshot.digest(before.dir));
		});
	}

	/** A commit made in the live tree is a snapshot of its own; the one taken before it stays as it was. */
	@:pin('control')
	@:killer('M-FROZEN-SNAPSHOT-KEY-CONSTANT')
	public function testACommitOfTheLiveTreeIsANewSnapshot(): Void {
		TempDir.with(dir -> {
			final live: String = LiveGitTree.make(dir);
			final cache: String = dir.file('cache');
			final first: FrozenTree = FrozenSnapshot.record(cache, live);
			File.saveContent(Path.join([live, 'a.hx']), 'class A { var second: Int; }\n');
			LiveGitTree.commit(live, 'second');
			final second: FrozenTree = FrozenSnapshot.record(cache, live);
			Assert.notEquals(first.dir, second.dir);
			Assert.notEquals(first.digest, second.digest);
			Assert.equals('class A {}\n', File.getContent(Path.join([first.dir, 'a.hx'])));
			Assert.equals(first.digest, FrozenSnapshot.digest(first.dir));
		});
	}

	/** A write into the snapshot, a new file or a removed one, moves its digest. */
	@:pin('control')
	@:killer('M-FROZEN-SNAPSHOT-DIGEST-BLIND')
	public function testAWriteIntoTheSnapshotMovesItsDigest(): Void {
		TempDir.with(dir -> {
			final recorded: FrozenTree = FrozenSnapshot.record(dir.file('cache'), LiveGitTree.make(dir));
			final file: String = Path.join([recorded.dir, 'a.hx']);
			File.saveContent(file, 'class A { var written: Int; }\n');
			Assert.notEquals(recorded.digest, FrozenSnapshot.digest(recorded.dir));
			FileSystem.deleteFile(file);
			Assert.notEquals(recorded.digest, FrozenSnapshot.digest(recorded.dir));
			File.saveContent(Path.join([recorded.dir, 'b.hx']), 'class B {}\n');
			Assert.notEquals(recorded.digest, FrozenSnapshot.digest(recorded.dir));
		});
	}

	/**
	 * A directory that is gone has a digest no recorded one equals; a record
	 * made before snapshots, of a live git tree, is read by its `git diff`.
	 */
	@:pin('control')
	@:killer('M-FROZEN-SNAPSHOT-DIGEST-BLIND')
	public function testAGoneDirectoryAndALegacyLiveRecordAreRead(): Void {
		TempDir.with(dir -> {
			final live: String = LiveGitTree.make(dir);
			Assert.equals(GateTree.diffDigest(live), FrozenSnapshot.digest(live));
			Assert.equals('missing', FrozenSnapshot.digest(dir.file('gone')));
		});
	}

	/** The live repository is only read: it gains no worktree entry and no ref. */
	@:pin('guard')
	public function testTheLiveRepositoryIsLeftAsItWas(): Void {
		TempDir.with(dir -> {
			final live: String = LiveGitTree.make(dir);
			final state: String -> String = tree ->
				cmd('git -C $tree worktree list').text() + cmd('git -C $tree status --porcelain').text();
			final before: String = state(live);
			Assert.isTrue(FileSystem.exists(FrozenSnapshot.record(dir.file('cache'), live).dir));
			Assert.equals(before, state(live));
			Assert.isFalse(FileSystem.exists(Path.join([live, '.git/worktrees'])));
		});
	}

}
