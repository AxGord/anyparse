package unit.cli;

import anyparse.check.oracle.HaxeRun;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.core.TempScratch;
import anyparse.query.Cli;
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

	private static var counter: Int = 0;

	/**
	 * Recursively delete `dir` and everything beneath it, tolerant of a
	 * missing path — a `dir` that does not exist is a silent no-op. The
	 * teardown counterpart to `writeDir`, centralizing the
	 * readDirectory + deleteFile + deleteDirectory recursion each CLI
	 * end-to-end test would otherwise reimplement.
	 */
	public static inline function removeDir(dir: String): Void {
		ScratchRoot.removeDir(dir);
	}

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
	 * Write each `{name, source}` into a fresh unique temp directory, creating the intermediate
	 * directories a NESTED `name` (`lib/deep/Deep.hx`) asks for, and return the directory path.
	 *
	 * The nested counterpart of `writeDir`: a fixture whose subject is where a file SITS — a
	 * per-directory ambient source, a package layout — cannot be written flat.
	 */
	public static function writeTree(prefix: String, files: Array<{ name: String, source: String }>): String {
		counter++;
		final root: String = '${TempScratch.root()}/tmp_${prefix}_tree_${Sys.time()}_$counter';
		FileSystem.createDirectory(root);
		for (f in files) {
			final target: String = '$root/${f.name}';
			FileSystem.createDirectory(Path.directory(target));
			File.saveContent(target, f.source);
		}
		return root;
	}

	/**
	 * Run `body`, then `cleanup` — whether `body` returns or throws. The try/finally Haxe does not
	 * spell, and what every fixture that writes a tree owes its own run: a failing assert would
	 * otherwise leave the tree, or a file it chmodded to mode 0, behind for the rest of the session.
	 */
	public static function always(cleanup: () -> Void, body: () -> Void): Void {
		try {
			body();
		} catch (exception: Exception) {
			cleanup();
			throw exception;
		}
		cleanup();
	}

	/**
	 * The repository root — the nearest ancestor of the process cwd holding `src/anyparse/check`.
	 *
	 * Here rather than in either caller because the on-disk drift guards need the same answer:
	 * `BuildMacroMetaSeamTest` locates the layer sources it scans for spelled grammar tags,
	 * `LintScopeGateTest` locates the `apq.json` documents whose resolution scope it asserts.
	 * Two copies of a walk-up are two things to keep in step.
	 *
	 * THROWS rather than returning null, which is what let both call sites collapse to one line.
	 * A `Null<String>` return is what the walk-up carried in `BuildMacroMetaSeamTest`, together
	 * with an assert-and-bail prologue whose `return` is a drift guard passing while guarding
	 * nothing — the one outcome a guard must not have, and it would have been copied
	 * here. The suite is documented to run with the cwd set to the tree it was built from
	 * (`dev worker-build`), so a cwd that cannot see the tree is a broken invocation, not a
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
	 * The CLI's diagnostics go to fd 2 through `CliIo.stderr`, which bottoms out in `fs.writeSync` — so the capture swaps that one
	 * function for the duration of the call and restores it on the way out, exceptions included. The swap answers the count of bytes it
	 * took, as the real call does: a writer that offers the rest of a short write again would otherwise never finish. Node only: on any
	 * other target the call runs and the caller gets `''`, which is why every test using this guards its assertions with `#if nodejs`.
	 */
	public static function captureStderr(fn: () -> Void): String {
		#if nodejs
		final buffer: Array<String> = [];
		final fs: Dynamic = js.Syntax.code('require("fs")'); // noqa: avoid-dynamic
		final original: Dynamic = fs.writeSync; // noqa: avoid-dynamic
		fs.writeSync = js.Syntax.code(
			'function(fd, data, offset, length) { if (fd !== 2) return {1}.apply(null, arguments); if (typeof data === "string") { {0}.push(data); return Buffer.byteLength(data); } {0}.push(data.toString("utf8", offset, offset + length)); return length; }', // noqa: fold-adjacent-string-literals
			buffer,
			original
		);
		try {
			fn();
		} catch (exception: haxe.Exception) {
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
		try {
			fn();
		} catch (exception: haxe.Exception) {
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

	/**
	 * `bin/apq.js`, or null after passing — the ONE owner of the "is the engine built?"
	 * question every child-process fixture in this suite has to ask.
	 *
	 * A fixture that spawns the CLI as a PROCESS needs a built `bin/apq.js`, and
	 * `haxe test-js.hxml` alone does not build one. A MUTATION TRACK never has it:
	 * `dev mutation-check` builds only `test.js`, into a directory of its own, and runs it
	 * with the CWD set to a fresh worktree whose gitignored `bin/` holds no engine — so
	 * `node bin/apq.js` there answers `MODULE_NOT_FOUND`, and the fixture reads as a failure of
	 * whatever the arm cut rather than of its own environment. Two classes carried a private copy
	 * of this guard and a third an inline one; the fourth fixture of the family had none, and it
	 * was `+extra` in EVERY non-fast arm run for as long as it existed.
	 */
	public static function engineOrSkip(): Null<String> {
		final engine: String = 'bin/apq.js';
		if (FileSystem.exists(engine)) return engine;
		Assert.pass('bin/apq.js is not built — a child-process fixture needs the CLI as a process');
		return null;
	}

	public static function git(root: String, args: Array<String>): Void {
		final run: HaxeRun = HaxeSpawn.exec({ cmd: 'git', args: args, cwd: root }, 1 << 20);
		if (run.failure != '' || run.status != 0) throw 'git ${args.join(' ')}: ${run.failure}${run.err}';
	}

	/** The command's stdout, run from `dir` — `changed` reads its paths relative to the working directory. */
	public static function inDir(dir: String, args: Array<String>): String {
		return runIn(dir, args).out;
	}

	/** The command's exit code and stdout, run from `dir`. */
	public static function runIn(dir: String, args: Array<String>): CliRun {
		final previous: String = Sys.getCwd();
		Sys.setCwd(dir);
		var code: Int = -1;
		final out: String = try {
			CliFixture.captureStdout(() -> code = Cli.run(args));
		} catch (exception: haxe.Exception) {
			Sys.setCwd(previous);
			throw exception;
		}
		Sys.setCwd(previous);
		return { code: code, out: out };
	}

}

/** What one `apq` run left: its exit code and its stdout. */
typedef CliRun = {
	final code: Int;
	final out: String;
}
