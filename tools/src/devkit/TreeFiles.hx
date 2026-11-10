package devkit;

import anyparse.util.Compare;
import haxe.io.Path;
import sys.FileSystem;

using StringTools;

/**
 * The one answer to "which files lie under a directory of a repo, recursively": every file, relative to the repo, sorted, in a
 * directory that is not a directory (or is missing) none. A directory is followed when `enter` accepts its name; symlinks resolve as
 * `FileSystem.isDirectory` resolves them.
 */
final class TreeFiles {

	/** Every file under `dir` of `repo`, as `dir`-prefixed paths, sorted; descends only into directories whose name `enter` accepts. */
	public static function below(repo: String, dir: String, enter: String -> Bool): Array<String> {
		final files: Array<String> = [];
		walk(repo, dir, enter, files);
		files.sort(Compare.compareString);
		return files;
	}

	/** Whether a directory name is not hidden (a leading dot). */
	public static function visible(name: String): Bool {
		return !name.startsWith('.');
	}

	private static function walk(repo: String, dir: String, enter: String -> Bool, files: Array<String>): Void {
		final full: String = Path.join([repo, dir]);
		if (!FileSystem.exists(full) || !FileSystem.isDirectory(full)) return;
		for (name in FileSystem.readDirectory(full)) {
			final child: String = Path.join([dir, name]);
			if (!FileSystem.isDirectory(Path.join([repo, child])))
				files.push(child);
			else if (enter(name))
				walk(repo, child, enter, files);
		}
	}

}
