package unit.cli;

import anyparse.core.TempScratch;
#if (sys || nodejs)
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
#end

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

	/**
	 * The scratch-directory prefix this suite claims, and the one `tools/tmp-lifecycle.sh`
	 * must list in `TMPL_PREFIXES` for an orphaned root to be reaped.
	 */
	private static inline final SCRATCH_PREFIX: String = 'apq-suite';

	/** The owner stamp that script reads: `<dir>/.apq-owner`, first line `pid <pid>`. */
	private static inline final OWNER_STAMP: String = '.apq-owner';

	/** Lowest six-digit value, so the fallback token is always exactly `mktemp`'s six characters. */
	private static inline final SCRATCH_TOKEN_LOW: Int = 100000;

	/** How many six-digit values the fallback token draws from. */
	private static inline final SCRATCH_TOKEN_SPAN: Int = 900000;

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
		final path: String = '${TempScratch.root()}/tmp_${prefix}_fixture_${Sys.time()}_$counter.$extension';
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
		final dir: String = '${TempScratch.root()}/tmp_${prefix}_dir_${Sys.time()}_$counter';
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
	 * Remove a scratch root this class CLAIMED, and refuse anything else BY NAME.
	 *
	 * `removeDir` deletes whatever it is handed, recursively. Handed the wrong path it is an
	 * `rm -rf` with no undo, and the wrong path is one edit away: while probing this very seam
	 * the runner's teardown was pointed at `repoRoot()` for a single build, and that run
	 * deleted the whole worktree it was running in. `tools/tmp-lifecycle.sh` already refuses a
	 * path outside its shape out loud rather than skipping it quietly (`tmpl_is_ours`); this is
	 * the same predicate on this side of the boundary — a basename of `apq-suite.` plus
	 * `mktemp`'s six characters, sitting under a directory of its own.
	 */
	public static function removeScratchRoot(dir: String): Void {
		final trimmed: String = Path.removeTrailingSlashes(dir);
		final base: String = Path.withoutDirectory(trimmed);
		final claimed: Bool = base.length == SCRATCH_PREFIX.length + 7 && base.indexOf('$SCRATCH_PREFIX.') == 0
			&& Path.directory(trimmed) != '';
		if (!claimed) throw new Exception('refusing to remove "$dir" — not a claimed $SCRATCH_PREFIX scratch root');
		removeDir(dir);
	}

	/**
	 * Point this process's `TMPDIR` at a private subdirectory of the OS temp dir and answer
	 * it; the caller removes it when the run ends (`removeScratchRoot`).
	 *
	 * A fixture name is unique only WITHIN a process — `counter` is a static and `Sys.time()`
	 * is a millisecond clock, and neither carries anything a second process cannot produce.
	 * Two suite processes started together are lockstep copies of each other, the same classes
	 * in the same order, so their counters advance side by side and land in the same
	 * millisecond: whole runs of names coincide, both write into ONE directory, and the first
	 * teardown deletes the other's fixture mid-test. Measured on `0430a5eb` with four
	 * concurrent suites: 19 non-green ROWS over 15 distinct fixtures in 7 classes, every one
	 * of them an `ENOENT` on a `$TMPDIR/tmp_…` path — and 0 with a private `TMPDIR` per
	 * process.
	 *
	 * A per-process ROOT rather than a per-process NAME because the naming is not in one
	 * place: TWENTY sites under test/ build such a path by hand — one of them a FIXED name no
	 * per-name fix could ever have reached — and `OracleCache` / `CompilerServer` key their
	 * records by an hxml+cwd hash under the same directory. One root covers every producer,
	 * including the ones not written yet.
	 *
	 * The root is CLAIMED the way `tools/tmp-lifecycle.sh` claims one — `apq-suite.XXXXXX`
	 * plus a `.apq-owner` stamp naming this pid — so the case the caller's teardown cannot
	 * reach, a SIGKILLed run, is swept by the tool that already owns that job for the other
	 * four scratch producers. Without that shape this would be the project's fifth scratch
	 * directory and the only one nothing reaps.
	 */
	public static function isolateTempDir(): String {
		final dir: String = makeScratchRoot(TempScratch.root());
		#if nodejs
		// The stamp `tools/tmp-lifecycle.sh` reads. Its sweep removes a claimed directory
		// whose owner pid is gone and whose entries have been untouched for the grace
		// window, so the one case the caller's teardown cannot reach — a SIGKILLed run — is
		// covered by the tool that already owns that job for the other four scratch producers.
		File.saveContent('$dir/$OWNER_STAMP', 'pid ${js.Node.process.pid}\ntool $SCRATCH_PREFIX\nstarted ${Std.int(Sys.time())}\n');
		#end
		Sys.putEnv('TMPDIR', dir);
		Sys.putEnv('TEMP', dir);
		return dir;
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
	 * nothing — the one outcome a guard must not have, and it would have been copied
	 * here. The suite is documented to run with the cwd set to the tree it was built from
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

	/**
	 * A fresh `apq-suite.XXXXXX` directory under `root`, created ATOMICALLY — `mkdtemp`
	 * fails rather than adopting an existing entry, which a `createDirectory` on a
	 * predictable name would silently do (hxnodejs swallows `EEXIST` whenever the path
	 * stats as a directory, symlinks followed). The name is `mktemp -d`'s exactly because
	 * `tools/tmp-lifecycle.sh` will only ever remove `<prefix>.` plus six characters.
	 */
	private static function makeScratchRoot(root: String): String {
		#if nodejs
		return js.node.Fs.mkdtempSync('$root/$SCRATCH_PREFIX.');
		#else
		// No portable `mkdtemp`; a six-digit draw keeps the shape mktemp gives and the
		// collision odds, and this branch never runs — the suite's only runner is node.
		final dir: String = '$root/$SCRATCH_PREFIX.${SCRATCH_TOKEN_LOW + Std.random(SCRATCH_TOKEN_SPAN)}';
		FileSystem.createDirectory(dir);
		return dir;
		#end
	}

	/**
	 * Run `fn` with stdout captured, and answer what it printed.
	 *
	 * The sibling of `captureStderr`, and the same mechanism: `CliIo.sysPrint`
	 * reaches `fs.writeSync(1, …)` on node, so intercepting `writeSync` catches
	 * everything the CLI writes without the test having to spawn a process.
	 * Needed by the `--help` and usage-page pins, which compare what the binary
	 * PRINTS against the bytes the pre-seam binary printed.
	 */
	public static function captureStdout(fn: () -> Void): String {
		#if nodejs
		final buffer: StringBuf = new StringBuf();
		final stdout: Dynamic = js.Node.process.stdout; // noqa: avoid-dynamic
		final original: Dynamic = Reflect.field(stdout, 'write'); // noqa: avoid-dynamic
		Reflect.setField(stdout, 'write', (chunk: Any) -> {
			buffer.add('$chunk');
			return true;
		});
		try fn() catch (exception: haxe.Exception) {
			Reflect.setField(stdout, 'write', original);
			throw exception;
		}
		Reflect.setField(stdout, 'write', original);
		return buffer.toString();
		#else
		fn();
		return '';
		#end
	}

}
