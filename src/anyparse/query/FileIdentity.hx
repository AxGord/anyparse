package anyparse.query;

import haxe.Exception;
import haxe.io.Path;

/**
 * The one answer to "which file is this path?": every site that keys, dedups or compares files by identity asks here,
 * so two spellings of one file — relative against absolute, through a symlinked root — can never key apart in one
 * place and together in another.
 */
@:nullSafety(Strict)
final class FileIdentity {

	/**
	 * `path` absolute, normalised and with every symlink resolved — the identity of a file however it is spelled. A path
	 * that does not exist yet resolves its nearest existing ancestor and keeps the rest, so it keys like the file it
	 * will become. Letter case is the caller's for every component no symlink rewrote: on a case-insensitive volume two
	 * case spellings of one file stay two identities, which refuses a merge rather than inventing one.
	 */
	public static function realPath(path: String): String {
		#if (sys || nodejs)
		final absolute: String = Path.removeTrailingSlashes(Path.normalize(sys.FileSystem.absolutePath(path)));
		if (sys.FileSystem.exists(absolute)) {
			// `fullPath` is declared non-null and on hxnodejs RETURNS null for a path it cannot resolve; the catch is for
			// the targets where it throws instead.
			final resolved: Null<String> = try sys.FileSystem.fullPath(absolute) catch (exception: Exception) null;
			return resolved == null || resolved == '' ? absolute : Path.normalize(resolved);
		}
		final parent: String = Path.directory(absolute);
		return parent == '' || parent == absolute ? absolute : Path.join([realPath(parent), Path.withoutDirectory(absolute)]);
		#else
		return path;
		#end
	}

}
