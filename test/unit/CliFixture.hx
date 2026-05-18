package unit;

#if sys
import sys.io.File;

/**
 * Shared on-disk fixture writer for the `apq` CLI end-to-end tests.
 *
 * Fixtures go into the OS temp directory, never the project root, so an
 * interrupted or killed test run cannot litter the repository (utest
 * `Assert` failures don't throw, so the per-test `deleteFile` still
 * runs on a normal failing assertion; a hard process kill skips it —
 * the temp-dir location is what keeps that case harmless).
 */
@:nullSafety(Strict)
final class CliFixture {

	private static var counter:Int = 0;

	/** Write `source` to a unique temp file and return its path. */
	public static function write(prefix:String, source:String):String {
		counter++;
		final path:String = '${tempDir()}/tmp_${prefix}_fixture_${Sys.time()}_$counter.hx';
		File.saveContent(path, source);
		return path;
	}

	private static function tempDir():String {
		final tmpdir:Null<String> = Sys.getEnv('TMPDIR');
		if (tmpdir != null && tmpdir.length > 0) return stripTrailingSlash(tmpdir);
		final temp:Null<String> = Sys.getEnv('TEMP');
		if (temp != null && temp.length > 0) return stripTrailingSlash(temp);
		return '/tmp';
	}

	private static inline function stripTrailingSlash(p:String):String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}
}
#end
