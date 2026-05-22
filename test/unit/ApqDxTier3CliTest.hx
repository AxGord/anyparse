package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end probes for the DX Tier-3 batch:
 *  1. `--regex` flag on `apq strip` and `apq recon --predict-strip`
 *     — EReg-mode patterns + backref replacement + compile-error
 *     reporting + cross-tool consistency.
 *  2. `apq sweep --save <path>` — copies the current snapshot to an
 *     arbitrary path; foundation for "save baseline before slice".
 *  3. `apq sweep --diff` (no arg) — defaults to `bin/.prev-sweep.json`
 *     (auto-rotated by the corpus harness).
 *  4. `apq test-summary` — parses utest stdout into tests/asserts/
 *     failures/errors; file path / `-` (stdin) / default `/tmp/test.out`
 *     resolution rules.
 *  5. `apq recon --candidates <regex>` — walks skip-parse fixtures and
 *     counts regex hits per file (cross-cluster construct enumeration).
 */
@:nullSafety(Strict)
class ApqDxTier3CliTest extends Test {

	// --- 1. --regex on strip ---

	public function testStripRegexBackrefReplacement():Void {
		#if sys
		final input:String = CliFixture.write('apq_regex_strip', 'class M { var x = new Foo<A, B, C>(1); var y = new Bar<X>(2); }');
		final exit:Int = Cli.run([
			'strip', input, '--regex',
			'--replace', 'new ([A-Z]\\w*)<[^>]+>\\(', '--with', 'new $1(',
		]);
		Assert.equals(0, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripRegexCompileErrorExitsUsage():Void {
		#if sys
		final input:String = CliFixture.write('apq_regex_strip', 'class M {}');
		// Unterminated character class — EReg construction throws. The
		// arg-validation path catches it before any FS apply and exits
		// EXIT_USAGE (2) with a stderr `--regex: pattern[idx] "..." is
		// not a valid EReg: ...` line.
		final exit:Int = Cli.run(['strip', input, '--regex', '--replace', 'foo[', '--with', 'x']);
		Assert.equals(2, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripRegexDryRunCountsMatches():Void {
		#if sys
		// Three calls to `new T<...>(` — regex `g` flag counts every one.
		final input:String = CliFixture.write('apq_regex_strip',
			'class M { var a = new Foo<X>(1); var b = new Foo<Y>(2); var c = new Bar<Z>(3); }');
		final exit:Int = Cli.run([
			'strip', input, '--regex', '--dry-run',
			'--replace', 'new \\w+<\\w+>\\(', '--with', '',
		]);
		Assert.equals(0, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 1b. --regex on recon predict-strip ---

	public function testReconRegexRequiresPredictStrip():Void {
		#if sys
		// `--regex` outside `--predict-strip` is a usage error — no
		// other mode in recon takes substitution patterns, so the flag
		// would be silently ignored otherwise. Surfacing it as USAGE
		// catches the user before they wonder why nothing happened.
		final exit:Int = Cli.run(['recon', '--regex']);
		Assert.equals(2, exit);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 2. sweep --save ---

	public function testSweepSaveCopiesSnapshot():Void {
		#if sys
		// Round-trip: write a known snapshot to the default file, ask
		// sweep to --save it to a temp path, verify the bytes match.
		final fakeJson:String = '{"pass":1,"fail":2,"skipParse":3,"skipWrite":0,"skipConfig":0,"skipMalformed":0,"fixtures":[]}';
		final src:String = CliFixture.writeAs('apq_sweep_save_src', 'json', fakeJson);
		final dst:String = CliFixture.writeAs('apq_sweep_save_dst', 'json', '');
		// Force the empty dst to be missing so --save creates it fresh.
		FileSystem.deleteFile(dst);
		final exit:Int = Cli.run(['sweep', '--file', src, '--save', dst]);
		Assert.equals(0, exit);
		Assert.isTrue(FileSystem.exists(dst));
		Assert.equals(fakeJson, File.getContent(dst));
		FileSystem.deleteFile(src);
		FileSystem.deleteFile(dst);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepSaveMissingFileExitsRuntime():Void {
		#if sys
		// Source snapshot doesn't exist → exit 1 before the copy.
		final missing:String = CliFixture.writeAs('apq_sweep_missing', 'json', '');
		FileSystem.deleteFile(missing);
		final dst:String = CliFixture.writeAs('apq_sweep_save_dst', 'json', '');
		FileSystem.deleteFile(dst);
		Assert.equals(1, Cli.run(['sweep', '--file', missing, '--save', dst]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 3. test-summary ---

	public function testTestSummaryParsesUtestTranscript():Void {
		#if sys
		final transcript:String = '  testFoo: OK ...\n  testBar: OK .\n  testBaz: FAIL: expected 1\n  testQux: ERROR: NPE\n';
		final path:String = CliFixture.writeAs('apq_test_summary', 'log', transcript);
		Assert.equals(0, Cli.run(['test-summary', path]));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryMissingDefaultExitsUsage():Void {
		#if sys
		// No positional + /tmp/test.out absent → usage error.
		if (FileSystem.exists('/tmp/test.out')) {
			Assert.pass('/tmp/test.out exists, skipping default-missing probe');
			return;
		}
		Assert.equals(2, Cli.run(['test-summary']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 4. recon --candidates ---

	public function testReconCandidatesMutexWithOtherModes():Void {
		#if sys
		// Combinable-with-nothing guard — surfaces a usage error
		// instead of silently picking one mode.
		Assert.equals(2, Cli.run(['recon', '--candidates', 'foo', '--predict-strip', '--delete', 'x']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconCandidatesInvalidRegexExitsUsage():Void {
		#if sys
		// EReg compile error reported with the same shape as strip --regex.
		Assert.equals(2, Cli.run(['recon', '--candidates', 'foo[']));
		#else
		Assert.pass('non-sys target');
		#end
	}
}
