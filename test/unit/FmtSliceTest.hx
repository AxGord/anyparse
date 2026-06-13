package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;

using StringTools;
#end

/**
 * End-to-end probe for `apq fmt` — the whole-file canonicaliser. Each test
 * writes a temp `.hx` fixture, drives it through `Cli.run(['fmt', ...])`, and
 * asserts on the exit code plus the on-disk result, covering the four modes:
 * `--write` (rewrite in place, idempotent), the no-flag single-file default
 * (formatted source to stdout, file untouched), `-l` list mode (non-
 * destructive), and the parse-failure / usage-error exits.
 *
 * Guarded `#if (sys || nodejs)` rather than the project's usual `#if sys` so
 * the fixtures and `Cli.run` actually execute on the JS (`-lib hxnodejs`)
 * test build — `#if sys` is FALSE under hxnodejs, which silently degrades a
 * `#if sys` CLI test to a no-op `Assert.pass` on the `node bin/test.js`
 * inner loop. `sys.io.File` / `FileSystem` / `Sys` all work on hxnodejs.
 */
class FmtSliceTest extends Test {

	/**
	 * A deliberately non-canonical module: no spaces around `:`/`=`, a glued
	 * class body, single-line members. The writer reflows all of it, so
	 * `fmt` output differs from the input on every target's default options.
	 */
	private static inline final NON_CANONICAL: String = 'package;\nclass C{var x:Int=1;function f(){return x;}}\n';

	#if (sys || nodejs)
	private static var counter: Int = 0;

	/** `--write` canonicalises in place and a second pass is a no-op. */
	public function testWriteCanonicalisesAndIsIdempotent(): Void {
		final f: String = fixture(NON_CANONICAL);
		Assert.equals(0, Cli.run(['fmt', f, '--write']));
		final canon: String = File.getContent(f);
		Assert.notEquals(NON_CANONICAL, canon);
		Assert.equals(0, Cli.run(['fmt', f, '--write']));
		Assert.equals(canon, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** A single file with no flags emits to stdout and leaves the file untouched. */
	public function testStdoutLeavesFileUnchanged(): Void {
		final f: String = fixture(NON_CANONICAL);
		Assert.equals(0, Cli.run(['fmt', f]));
		Assert.equals(NON_CANONICAL, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** `-l` (list) reports drift without rewriting — the file is unchanged. */
	public function testListLeavesFileUnchanged(): Void {
		final f: String = fixture(NON_CANONICAL);
		Assert.equals(0, Cli.run(['fmt', f, '-l']));
		Assert.equals(NON_CANONICAL, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** An already-canonical file is left byte-identical under `--write`. */
	public function testAlreadyCanonicalIsUntouched(): Void {
		final f: String = fixture(NON_CANONICAL);
		Cli.run(['fmt', f, '--write']);
		final canon: String = File.getContent(f);
		final g: String = fixture(canon);
		Assert.equals(0, Cli.run(['fmt', g, '--write']));
		Assert.equals(canon, File.getContent(g));
		FileSystem.deleteFile(f);
		FileSystem.deleteFile(g);
	}

	/** An unparseable file exits `EXIT_RUNTIME` and is not rewritten. */
	public function testParseFailureExitsRuntime(): Void {
		final broken: String = 'package;\nclass C {\n';
		final f: String = fixture(broken);
		Assert.equals(1, Cli.run(['fmt', f, '--write']));
		Assert.equals(broken, File.getContent(f));
		FileSystem.deleteFile(f);
	}

	/** No input specs is a usage error. */
	public function testNoInputsIsUsageError(): Void {
		Assert.equals(2, Cli.run(['fmt']));
	}

	private static function fixture(source: String): String {
		counter++;
		final env: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = env != null && env.length > 0 ? env.endsWith('/') ? env.substr(0, env.length - 1) : env : '/tmp';
		final path: String = '$base/tmp_apq_fmt_${Sys.time()}_$counter.hx';
		File.saveContent(path, source);
		return path;
	}
	#else
	public function testNonSysTarget(): Void {
		Assert.pass('apq fmt requires a sys / nodejs target');
	}
	#end

}
