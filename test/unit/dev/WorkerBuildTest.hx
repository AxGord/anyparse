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

	@:pin('control')
	@:killer('M-WORKER-BUILD-HXML-UNCHECKED')
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
			var refusal: String = '';
			try
				WorkerBuild.main([sibling, '--repo', emptyRepo])
			catch (exception: UsageError)
				refusal = exception.message;
			Assert.stringContains(
				'bin/apq-js-common.hxml', refusal,
				'a sibling passes both guards, and a repo without the build files is refused naming the file before any haxe call can '
				+ 'print its own error'
			);
			Assert.same([], FileSystem.readDirectory(sibling), 'the refusal starts no build, so nothing is written');
			WorkerBuild.refuseTreeRoot(Path.join([root, 'bin']));
			Assert.pass('the root\'s gitignored bin/ is not refused');
		});
	}

}
