package unit.devkit;

import anyparse.core.TempScratch;
import devkit.TempDir;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `TempDir` — a directory of the run's own, stamped the way `devkit.TmpLifecycle` reads an owner, and gone once its
 * owner is done with it, by return or by throw.
 */
@:nullSafety(Strict)
final class TempDirTest extends Test {

	public function testADirectoryIsStampedWithItsOwner(): Void {
		final dir: TempDir = TempDir.create();
		Assert.isTrue(FileSystem.isDirectory(dir.path));
		Assert.equals(Path.normalize(TempScratch.root()), Path.normalize(Path.directory(dir.path)));
		Assert.isTrue(~/^apq-dev\.[A-Za-z0-9]{6}$/.match(Path.withoutDirectory(dir.path)), 'the shape the sweep accepts');
		final stamp: String = File.getContent(dir.file('.apq-owner'));
		Assert.isTrue(stamp.startsWith('pid ${js.Node.process.pid}\ntool apq-dev\nstarted '), stamp);
		dir.dispose();
		Assert.isFalse(FileSystem.exists(dir.path));
		dir.dispose();
	}

	public function testWithRemovesTheDirectoryOnReturnAndOnThrow(): Void {
		var seen: String = '';
		final answer: Int = TempDir.with(dir -> {
			seen = dir.path;
			File.saveContent(dir.file('x'), 'x');
			return 7;
		});
		Assert.equals(7, answer);
		Assert.isFalse(FileSystem.exists(seen));
		Assert.raises(
			() -> TempDir.with(dir -> {
				seen = dir.path;
				throw new Exception('inside');
			}),
			Exception
		);
		Assert.isFalse(FileSystem.exists(seen));
	}

}
