package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
#end

/**
 * `apq lit / refs / uses / meta` skip-parse warning surfaces the failure
 * locus (`LINE:COL <message>`) alongside the path. Before this slice the
 * warning was `skip: <path>` only, leaving the reader to follow up with a
 * `hxq ast <path>` probe to learn whether the parse failure was upstream
 * of the searched-for content or far past it. The locus is computed once
 * inside `parseWalked` via `Span.lineCol(source)`; the walker no longer
 * pushes raw paths into `skipPaths` — `parseWalked` populates `skipEntries`
 * via its `?skipOut` out-parameter.
 *
 * Tests exercise the new code path with a directory mixing one parseable
 * file and one syntactically-broken file. `Cli.run` exits 0 (a 0-hit scan
 * is not an error) and the skip-parse warning is emitted to stderr — text
 * content verified manually during the slice that added the locus.
 */
@:nullSafety(Strict)
class ApqSkipParseLocusTest extends Test {

	public function testLitScanWithBrokenFileExitsClean():Void {
		#if sys
		final dir:String = writeMixedDir();
		Assert.equals(0, Cli.run(['lit', 'nothingHere', dir]),
			'scan with broken sibling file is a clean 0-hit, not an error');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRefsScanWithBrokenFileExitsClean():Void {
		#if sys
		final dir:String = writeMixedDir();
		Assert.equals(0, Cli.run(['refs', 'nothingHere', dir]),
			'refs scan with broken sibling file is a clean 0-hit');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUsesScanWithBrokenFileExitsClean():Void {
		#if sys
		final dir:String = writeMixedDir();
		Assert.equals(0, Cli.run(['uses', 'NotHere', dir]),
			'uses scan with broken sibling file is a clean 0-hit');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMetaScanWithBrokenFileExitsClean():Void {
		#if sys
		final dir:String = writeMixedDir();
		Assert.equals(0, Cli.run(['meta', '@:absentMeta', dir]),
			'meta scan with broken sibling file is a clean 0-hit');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// Single-file mode: broken file is itself the query target. Returns
	// EXIT_RUNTIME and prints the parse error to stderr directly (no
	// skip-warning path) — pre-existing behaviour, locked in here to
	// guard against the parseWalked signature change.

	public function testSingleBrokenFileIsRuntimeError():Void {
		#if sys
		final path:String = CliFixture.write('apq_skip_parse_single_broken', 'class C { var x:');
		Assert.notEquals(0, Cli.run(['lit', 'nothing', path]),
			'single broken file is a runtime error, not a 0-hit warning');
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeMixedDir():String {
		return CliFixture.writeDir('apq_skip_parse_locus', [
			{name: 'Good.hx', source: 'class Good { var y:Int = 0; }'},
			{name: 'Bad.hx', source: 'class Bad { var z:'},
		]);
	}

	private static function cleanupDir(dir:String):Void {
		for (entry in FileSystem.readDirectory(dir))
			FileSystem.deleteFile('$dir/$entry');
		FileSystem.deleteDirectory(dir);
	}
	#end
}
