package anyparse.query;

/**
 * Walks up the directory tree from a file looking for a named project config,
 * returning its content. The shared IO half of every walk-up config lookup
 * (`checkstyle.json` via `CheckstyleConfigFinder`, `apqlint.json` via
 * `LintConfig.discover`); the conditional compilation for file IO lives here in
 * one place so callers stay target-agnostic.
 */
@:nullSafety(Strict)
final class ConfigFinder {

	/**
	 * Walk up from `path`'s directory looking for a file named `filename` and
	 * return its content, or null when none is found, it cannot be read, or the
	 * target has no file IO.
	 */
	public static function findUp(path: String, filename: String): Null<String> {
		#if (sys || nodejs)
		var dir: String = haxe.io.Path.directory(sys.FileSystem.absolutePath(path));
		while (dir != '') {
			final candidate: String = dir + '/' + filename;
			if (sys.FileSystem.exists(candidate) && !sys.FileSystem.isDirectory(candidate))
				return try sys.io.File.getContent(candidate) catch (exception: haxe.Exception) null;
			final parent: String = haxe.io.Path.directory(dir);
			if (parent == dir) break;
			dir = parent;
		}
		return null;
		#else
		return null;
		#end
	}

}
