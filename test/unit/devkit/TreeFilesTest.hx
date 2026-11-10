package unit.devkit;

import devkit.TempDir;
import devkit.TreeFiles;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `TreeFiles` — every file under a directory, sorted, with the caller deciding which directories are entered. */
@:nullSafety(Strict)
final class TreeFilesTest extends Test {

	public function testListsEveryFileSortedAndRelativeToTheRepo(): Void {
		TempDir.with(dir -> {
			lay(dir, ['t/b.hx', 't/a/z.hx', 't/a/y.txt', 't/.hid/h.hx', 't/.dot.hx']);
			Assert.same(['t/.dot.hx', 't/.hid/h.hx', 't/a/y.txt', 't/a/z.hx', 't/b.hx'], TreeFiles.below(dir.path, 't', _ -> true));
		});
	}

	public function testEnterDecidesWhichDirectoriesAreDescended(): Void {
		TempDir.with(dir -> {
			lay(dir, ['t/b.hx', 't/.hid/h.hx', 't/a/z.hx']);
			Assert.same(['t/.hid/h.hx', 't/a/z.hx', 't/b.hx'], TreeFiles.below(dir.path, 't', _ -> true));
			Assert.same(['t/a/z.hx', 't/b.hx'], TreeFiles.below(dir.path, 't', TreeFiles.visible));
		});
	}

	public function testAMissingDirectoryOrAFileHoldsNothing(): Void {
		TempDir.with(dir -> {
			lay(dir, ['t/f.hx']);
			Assert.same([], TreeFiles.below(dir.path, 'none', _ -> true));
			Assert.same([], TreeFiles.below(dir.path, 't/f.hx', _ -> true));
		});
	}

	private static function lay(dir: TempDir, files: Array<String>): Void {
		for (file in files) {
			final full: String = dir.file(file);
			if (!FileSystem.exists(Path.directory(full))) FileSystem.createDirectory(Path.directory(full));
			File.saveContent(full, '');
		}
	}

}
