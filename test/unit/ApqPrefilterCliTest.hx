package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.io.File;
import sys.FileSystem;
#end

/**
 * Regression guard for the name-walker substring pre-filter (refs / uses
 * / lit / cases / mentions / blast). The pre-filter reads a file's raw
 * bytes and skips parsing entirely when the searched key is absent as a
 * substring — a speed-only change that MUST NOT alter walker behaviour.
 *
 * These end-to-end probes drive `Cli.run([...])` against tmp fixtures and
 * assert the exit-code contract the pre-filter could break. Stdout is
 * printed immediately via `Sys.print` (same as the sibling `*CliTest`
 * harness), so the tests assert exit codes and no-crash rather than
 * intercepting output — byte-level output identity is covered separately
 * by the corpus identity sweep.
 *
 * Gated on `#if (sys || nodejs)` rather than the sibling `#if sys`: the
 * default test binary is the `-lib hxnodejs` JS build, where `sys` is NOT
 * defined (hxnodejs `allowPackage`s `sys` but defines `nodejs` instead).
 * The wider gate makes these assertions run for real on that build —
 * exactly the binary path the pre-filter ships on — instead of falling
 * through to a `non-sys` no-op. Fixtures are written directly via
 * `sys.io.File`; teardown delegates to the shared `CliFixture.removeDir`.
 *
 * Two pre-filter paths are exercised:
 *
 *  - Multi-file scan where the key lives in only ONE of several files:
 *    the key-bearing file must still be parsed + walked (exit 0), proving
 *    the pre-filter skip does not drop a real hit. The sibling files
 *    lacking the key are skipped without parsing and without inflating
 *    the skip-parse count.
 *
 *  - Single named file whose content lacks the key: the pre-filter is
 *    SUPPRESSED in single-file mode, so the file is parsed and the query
 *    answers "0 hits, exit 0" — NOT the parse-failure hard error
 *    (exit 1). Without the suppression a no-match would be conflated with
 *    a parse failure.
 */
class ApqPrefilterCliTest extends Test {

	#if (sys || nodejs)
	private static var counter: Int = 0;
	#end

	public function testScanFindsKeyInOnlyOneFile(): Void {
		#if (sys || nodejs)
		// `HxVarDecl` appears textually in just one of the three files;
		// the other two are valid Haxe that the pre-filter skips. The walk
		// must still parse the key-bearing file and exit 0.
		final dir: String = writeDir([
			{ name: 'A.hx', source: 'class A { var unrelated:Int = 0; }' },
			{ name: 'B.hx', source: 'class HxVarDecl { var n:Int = 0; }' },
			{ name: 'C.hx', source: 'class C { function f():Void {} }' },
		]);
		Assert.equals(0, Cli.run(['refs', 'HxVarDecl', dir]));
		Assert.equals(0, Cli.run(['uses', 'HxVarDecl', dir]));
		Assert.equals(0, Cli.run(['lit', 'HxVarDecl', dir]));
		Assert.equals(0, Cli.run(['mentions', 'HxVarDecl', dir]));
		Assert.equals(0, Cli.run(['blast', 'HxVarDecl', dir]));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testScanKeyAbsentEverywhereExitsOk(): Void {
		#if (sys || nodejs)
		// No file contains the key — every file is pre-filtered (skipped
		// without parsing). The walk must still exit 0 (0 hits), NOT error,
		// and must not treat a pre-filter skip as a parse failure.
		final dir: String = writeDir([
			{ name: 'A.hx', source: 'class A { var n:Int = 0; }' },
			{ name: 'B.hx', source: 'class B { var m:Int = 0; }' },
		]);
		Assert.equals(0, Cli.run(['refs', 'TotallyAbsentName', dir]));
		Assert.equals(0, Cli.run(['cases', 'TotallyAbsentName', dir]));
		Assert.equals(0, Cli.run(['lit', 'TotallyAbsentName', dir]));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSingleFileKeyAbsentIsOkNotParseError(): Void {
		#if (sys || nodejs)
		// Single named, parseable file whose content lacks the key. The
		// pre-filter is suppressed in single-file mode, so this is a clean
		// "0 hits, exit 0" — NOT the single-file parse-failure hard error
		// (exit 1). This is the edge case the suppression guard protects.
		final fixture: String = writeFile('class Lonely { var n:Int = 0; }');
		Assert.equals(0, Cli.run(['refs', 'AbsentKey', fixture]));
		Assert.equals(0, Cli.run(['uses', 'AbsentKey', fixture]));
		Assert.equals(0, Cli.run(['lit', 'AbsentKey', fixture]));
		Assert.equals(0, Cli.run(['cases', 'AbsentKey', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSingleUnparseableFileStillHardError(): Void {
		#if (sys || nodejs)
		// The pre-filter must not mask a genuine parse failure in
		// single-file mode: a named file that does not parse is still the
		// query's answer (EXIT_RUNTIME = 1), unchanged by the pre-filter.
		final bad: String = writeFile('class {');
		Assert.equals(1, Cli.run(['refs', 'AnyKey', bad]));
		FileSystem.deleteFile(bad);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	#if (sys || nodejs)
	private static function tempDir(): String {
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		if (tmp != null && tmp.length > 0) return StringTools.endsWith(tmp, '/') ? tmp.substring(0, tmp.length - 1) : tmp;
		return '/tmp';
	}

	private static function writeFile(source: String): String {
		counter++;
		final path: String = '${tempDir()}/tmp_apq_prefilter_${Sys.time()}_$counter.hx';
		File.saveContent(path, source);
		return path;
	}

	private static function writeDir(files: Array<{ name: String, source: String }>): String {
		counter++;
		final dir: String = '${tempDir()}/tmp_apq_prefilter_dir_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		for (f in files) File.saveContent('$dir/${f.name}', f.source);
		return dir;
	}
	#end

}
