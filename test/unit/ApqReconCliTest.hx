package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `apq recon` — corpus skip-parse drill harness end-to-end probe.
 *
 * Sweep mode walks `.hxtest` files under a directory, runs the trivia
 * parser per fixture, prints `SKIP <path> :: <line>:<col> …` for each
 * failure, then a normalised-locus cluster histogram. `--probe <file>`
 * runs a single file as PARSE OK / PARSE FAIL.
 *
 * Replaces the standalone `test/_ReconSkipParse.hx` + `/tmp/recon.js`
 * dance — same clustering logic, in-process so a `bin/apq-js.hxml`
 * rebuild after a grammar edit picks up the new parser surface without
 * a separate `recon.hxml` step.
 *
 * Tests drive `Cli.run`. The stderr / stdout text content was verified
 * manually against the haxe-formatter fork on disk; here we only assert
 * exit codes and structural argv handling.
 */
@:nullSafety(Strict)
class ApqReconCliTest extends Test {

	public function testReconHelpExitsClean():Void {
		Assert.equals(0, Cli.run(['recon', '--help']),
			'apq recon --help is a clean exit');
	}

	public function testReconNoArgsAndNoEnvIsUsageError():Void {
		#if sys
		final saved:Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		Sys.putEnv('ANYPARSE_HXFORMAT_FORK', '');
		Assert.equals(2, Cli.run(['recon']),
			'no <dir> and no fork env var is a usage error');
		if (saved != null) Sys.putEnv('ANYPARSE_HXFORMAT_FORK', saved);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconMissingDirIsRuntimeError():Void {
		#if sys
		Assert.equals(1, Cli.run(['recon', '/nonexistent/path/that/does/not/exist']),
			'non-existent <dir> is a runtime error');
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconUnknownOptionIsUsageError():Void {
		Assert.equals(2, Cli.run(['recon', '--bogus']),
			'unknown option is a usage error');
	}

	public function testReconTwoPositionalsIsUsageError():Void {
		Assert.equals(2, Cli.run(['recon', '/a', '/b']),
			'two positional <dir> args is a usage error');
	}

	public function testReconTopRequiresPositiveInt():Void {
		Assert.equals(2, Cli.run(['recon', '--top', 'nope', '/some/dir']),
			'non-integer --top is a usage error');
		Assert.equals(2, Cli.run(['recon', '--top', '0', '/some/dir']),
			'zero --top is a usage error');
		Assert.equals(2, Cli.run(['recon', '--top', '-3', '/some/dir']),
			'negative --top is a usage error');
	}

	// -- Sweep mode against a tiny on-disk corpus --

	public function testReconSweepOnEmptyDirExitsClean():Void {
		#if sys
		final dir:String = mkTempDir('apq_recon_empty');
		Assert.equals(0, Cli.run(['recon', dir]),
			'empty corpus is a clean 0-total sweep');
		FileSystem.deleteDirectory(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconSweepOnGoodFixtureExitsClean():Void {
		#if sys
		final dir:String = mkTempDir('apq_recon_good');
		File.saveContent('$dir/good.hxtest', goodHxtest());
		Assert.equals(0, Cli.run(['recon', dir]),
			'all-OK sweep exits 0');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconSweepWithBrokenFixtureExitsClean():Void {
		#if sys
		final dir:String = mkTempDir('apq_recon_broken');
		File.saveContent('$dir/good.hxtest', goodHxtest());
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		// SKIPs are not errors — exit 0, histogram shows the cluster.
		Assert.equals(0, Cli.run(['recon', dir]),
			'sweep with one broken fixture still exits 0 (SKIP is data, not an error)');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconSweepRecursesIntoSubdirs():Void {
		#if sys
		final dir:String = mkTempDir('apq_recon_nested');
		FileSystem.createDirectory('$dir/inner');
		File.saveContent('$dir/inner/good.hxtest', goodHxtest());
		Assert.equals(0, Cli.run(['recon', dir]),
			'sweep recurses into nested subdirectories');
		cleanupDir('$dir/inner');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- Single-file probe mode --

	public function testReconProbeGoodFixtureExitsClean():Void {
		#if sys
		final dir:String = mkTempDir('apq_recon_probe_good');
		final path:String = '$dir/ok.hxtest';
		File.saveContent(path, goodHxtest());
		Assert.equals(0, Cli.run(['recon', '--probe', path]),
			'probe of a parseable .hxtest returns PARSE OK / exit 0');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconProbeBrokenFixtureIsRuntimeError():Void {
		#if sys
		final dir:String = mkTempDir('apq_recon_probe_bad');
		final path:String = '$dir/bad.hxtest';
		File.saveContent(path, brokenHxtest());
		Assert.equals(1, Cli.run(['recon', '--probe', path]),
			'probe of an unparseable .hxtest is PARSE FAIL / exit 1');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconProbeNonexistentIsRuntimeError():Void {
		#if sys
		Assert.equals(1, Cli.run(['recon', '--probe', '/no/such/file.hxtest']),
			'probe of a missing file is a runtime error');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static var counter:Int = 0;

	private static function mkTempDir(prefix:String):String {
		counter++;
		final tmp:Null<String> = Sys.getEnv('TMPDIR');
		final base:String = (tmp != null && tmp.length > 0) ? stripTrailingSlash((tmp : String)) : '/tmp';
		final dir:String = '$base/${prefix}_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		return dir;
	}

	private static function cleanupDir(dir:String):Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final p:String = '$dir/$entry';
			if (FileSystem.isDirectory(p)) cleanupDir(p);
			else FileSystem.deleteFile(p);
		}
		FileSystem.deleteDirectory(dir);
	}

	private static inline function stripTrailingSlash(p:String):String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}

	private static inline function goodHxtest():String {
		return '{}\n---\n\nclass C { var x:Int = 0; }\n\n---\n\nclass C {\n\tvar x:Int = 0;\n}\n';
	}

	private static inline function brokenHxtest():String {
		// Trailing colon with no type — trivia parser must reject.
		return '{}\n---\n\nclass C { var x:\n\n---\n\nclass C {\n\tvar x:Int;\n}\n';
	}
	#end
}
