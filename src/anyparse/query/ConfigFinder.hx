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
		final found: Null<{ content: String, path: String }> = findUpFile(path, filename);
		return found == null ? null : found.content;
	}

	/**
	 * As `findUp`, but also returns the ABSOLUTE path of the config that matched, so
	 * a caller can resolve a config-relative setting (the `apqlint.json`
	 * `compilerOracle` hxml) against the config's own directory. Null when none is
	 * found, unreadable, or the target has no file IO.
	 */
	public static function findUpFile(path: String, filename: String): Null<{ content: String, path: String }> {
		#if (sys || nodejs)
		var dir: String = haxe.io.Path.directory(sys.FileSystem.absolutePath(path));
		while (dir != '') {
			final candidate: String = dir + '/' + filename;
			if (sys.FileSystem.exists(candidate) && !sys.FileSystem.isDirectory(candidate)) {
				final content: Null<String> = try sys.io.File.getContent(candidate) catch (exception: haxe.Exception) null;
				return content == null ? null : { content: content, path: candidate };
			}
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
