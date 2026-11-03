package unit.dev;

import dev.WorkerBuild;
import devkit.Args.UsageError;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev worker-build`'s refusals, each before anything is built: no workdir, an empty one, an unknown target. The build
 * itself and the shared-`bin/` guard are proven against the shell twin by running both.
 */
@:nullSafety(Strict)
final class WorkerBuildTest extends Test {

	public function testACommandLineItCannotBuildFromIsRefused(): Void {
		TempDir.with(dir -> {
			final workdir: String = dir.file('w');
			Assert.raises(() -> WorkerBuild.main([]), UsageError, 'no workdir');
			Assert.raises(() -> WorkerBuild.main(['']), UsageError, 'an empty workdir');
			Assert.raises(() -> WorkerBuild.main([workdir, 'bogus']), UsageError, 'an unknown target');
			Assert.isFalse(FileSystem.exists(workdir), 'a refusal creates nothing');
		});
	}

	public function testATreeRootIsRefusedAndWrittenNowhereWhileASiblingPasses(): Void {
		TempDir.with(dir -> {
			final root: String = dir.file('tree');
			FileSystem.createDirectory(Path.join([root, '.git']));
			Assert.raises(() -> WorkerBuild.main([root, '--repo', root]), UsageError, 'the root of a git tree');
			Assert.same(['.git'], FileSystem.readDirectory(root), 'a refusal writes nothing into the tree');
			final linked: String = dir.file('linked');
			FileSystem.createDirectory(linked);
			File.saveContent(Path.join([linked, '.git']), 'gitdir: elsewhere\n');
			Assert.raises(() -> WorkerBuild.main([linked, '--repo', root]), UsageError, 'the root of a linked worktree');
			final sibling: String = dir.file('private');
			final emptyRepo: String = dir.file('empty');
			FileSystem.createDirectory(emptyRepo);
			Assert.equals(
				1, WorkerBuild.main([sibling, '--repo', emptyRepo]),
				'a sibling passes the guard and reaches the build, which fails for want of an hxml'
			);
			Assert.isTrue(FileSystem.exists(Path.join([sibling, 'build-apq.log'])), 'the build wrote its log into the sibling');
			WorkerBuild.refuseTreeRoot(Path.join([root, 'bin']));
			Assert.pass('the root\'s gitignored bin/ is not refused');
		});
	}

}
