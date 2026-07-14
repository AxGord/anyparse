package unit;

#if (sys || nodejs)
import sys.FileSystem;
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

	private static var counter: Int = 0;

	/** Write `source` to a unique temp `.hx` file and return its path. */
	public static function write(prefix: String, source: String): String {
		return writeAs(prefix, 'hx', source);
	}

	/**
	 * Write `content` to a unique temp file with `extension` (no dot)
	 * and return its path. Use the `.hx`-shorthand `write` when the
	 * fixture is a Haxe source file; use this entry for expected-output
	 * comparison files (`.txt`) or other extensions.
	 */
	public static function writeAs(prefix: String, extension: String, content: String): String {
		counter++;
		final path: String = '${tempDir()}/tmp_${prefix}_fixture_${Sys.time()}_$counter.$extension';
		File.saveContent(path, content);
		return path;
	}

	/**
	 * Write each `{name, source}` into a fresh unique temp directory and
	 * return the directory path — for exercising the CLI's directory-walk
	 * (scan) mode with a mix of parseable and unparseable files.
	 */
	public static function writeDir(prefix: String, files: Array<{ name: String, source: String }>): String {
		counter++;
		final dir: String = '${tempDir()}/tmp_${prefix}_dir_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		for (f in files) File.saveContent('$dir/${f.name}', f.source);
		return dir;
	}

	/**
	 * Recursively delete `dir` and everything beneath it, tolerant of a
	 * missing path — a `dir` that does not exist is a silent no-op. The
	 * teardown counterpart to `writeDir`, centralizing the
	 * readDirectory + deleteFile + deleteDirectory recursion each CLI
	 * end-to-end test would otherwise reimplement.
	 */
	public static function removeDir(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final p: String = '$dir/$entry';
			if (FileSystem.isDirectory(p))
				removeDir(p);
			else
				FileSystem.deleteFile(p);
		}
		FileSystem.deleteDirectory(dir);
	}

	private static function tempDir(): String {
		final tmpdir: Null<String> = Sys.getEnv('TMPDIR');
		if (tmpdir != null && tmpdir.length > 0) return stripTrailingSlash(tmpdir);
		final temp: Null<String> = Sys.getEnv('TEMP');
		if (temp != null && temp.length > 0) return stripTrailingSlash(temp);
		return '/tmp';
	}

	private static inline function stripTrailingSlash(p: String): String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}

}
#end
