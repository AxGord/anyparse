package unit;

#if (sys || nodejs)
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

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

	/**
	 * The repository root — the nearest ancestor of the process cwd holding `src/anyparse/check`.
	 *
	 * Here rather than in either caller because the on-disk drift guards need the same answer:
	 * `BuildMacroMetaSeamTest` locates the layer sources it scans for spelled grammar tags,
	 * `LintScopeGateTest` locates the `apqlint.json` documents whose resolution scope it asserts.
	 * Two copies of a walk-up are two things to keep in step.
	 *
	 * THROWS rather than returning null, which is what let both call sites collapse to one line.
	 * A `Null<String>` return is what the walk-up carried in `BuildMacroMetaSeamTest`, together
	 * with an assert-and-bail prologue whose `return` is a drift guard passing while guarding
	 * nothing — the one outcome a guard must not have, and it would have been copied here. The suite is documented to run with the cwd set to the tree it was built from
	 * (`tools/worker-build.sh`), so a cwd that cannot see the tree is a broken invocation, not a
	 * configuration to tolerate.
	 */
	public static function repoRoot(): String {
		final cwd: String = Path.removeTrailingSlashes(Path.normalize(Sys.getCwd()));
		var dir: String = cwd;
		for (_ in 0...8) {
			if (FileSystem.exists('$dir/src/anyparse/check')) return dir;
			final up: String = Path.removeTrailingSlashes(Path.normalize('$dir/..'));
			if (up == dir) break;
			dir = up;
		}
		throw new Exception('src/anyparse/check is not above the cwd ($cwd) - run the suite from the tree it was built from');
	}

	/**
	 * Everything `fn` writes to STDERR, captured rather than printed.
	 *
	 * The CLI's diagnostics go to fd 2 through `Sys.stderr()`, which on hxnodejs
	 * bottoms out in `fs.writeSync` — so the capture swaps that one function for the
	 * duration of the call and restores it on the way out, exceptions included. Node
	 * only: on any other target the call runs and the caller gets `''`, which is why
	 * every test using this guards its assertions with `#if nodejs`.
	 */
	public static function captureStderr(fn: () -> Void): String {
		#if nodejs
		final buffer: Array<String> = [];
		final fs: Dynamic = js.Syntax.code('require("fs")'); // noqa: avoid-dynamic
		final original: Dynamic = fs.writeSync; // noqa: avoid-dynamic
		fs.writeSync = js.Syntax.code(
			'function(fd, data) { if (fd === 2) { {0}.push(String(data)); return 0; } return {1}.apply(null, arguments); }', buffer,
			original
		);
		try fn() catch (exception: haxe.Exception) {
			fs.writeSync = original;
			throw exception;
		}
		fs.writeSync = original;
		return buffer.join('');
		#else
		fn();
		return '';
		#end
	}

	private static inline function stripTrailingSlash(p: String): String {
		return p.endsWith('/') ? p.substring(0, p.length - 1) : p;
	}

	private static function tempDir(): String {
		final tmpdir: Null<String> = Sys.getEnv('TMPDIR');
		if (tmpdir != null && tmpdir.length > 0) return stripTrailingSlash(tmpdir);
		final temp: Null<String> = Sys.getEnv('TEMP');
		return temp != null && temp.length > 0 ? stripTrailingSlash(temp) : '/tmp';
	}

}
#end
