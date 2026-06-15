package anyparse.grammar.haxe;

/**
 * Locates a project `checkstyle.json` on disk — the IO half of the checkstyle
 * config support, kept apart from the pure `CheckstyleConfigLoader` (which only
 * maps already-read JSON onto neutral check config) so the disk walk's
 * conditional compilation lives in one place. Every consumer of a project
 * checkstyle config discovers the file through here: the naming policy
 * (`HaxeNamingSupport.policyFor`) and the complexity threshold
 * (`HaxeQueryPlugin.maxComplexity`) both resolve it this way.
 */
@:nullSafety(Strict)
final class CheckstyleConfigFinder {

	/**
	 * Walk up from `path`'s directory looking for a `checkstyle.json` and return
	 * its content, or null when none is found, cannot be read, or on a target
	 * without file IO.
	 */
	public static function findConfigContent(path: String): Null<String> {
		#if (sys || nodejs)
		var dir: String = haxe.io.Path.directory(sys.FileSystem.absolutePath(path));
		while (dir != '') {
			final candidate: String = dir + '/checkstyle.json';
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
