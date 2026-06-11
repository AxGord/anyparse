package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
import anyparse.query.Cli.TestSummaryFailureKind;
import anyparse.query.Cli.TestSummaryFailureLocus;
import anyparse.query.Cli.TestSummaryResult;
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

	public function testStripRegexBackrefReplacement(): Void {
		#if sys
		final input: String = CliFixture.write('apq_regex_strip', 'class M { var x = new Foo<A, B, C>(1); var y = new Bar<X>(2); }');
		final exit: Int = Cli.run([
			'strip',
			input,
			'--regex',
			'--replace',
			'new ([A-Z]\\w*)<[^>]+>\\(',
			'--with',
			'new $1(',
		]);
		Assert.equals(0, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripRegexCompileErrorExitsUsage(): Void {
		#if sys
		final input: String = CliFixture.write('apq_regex_strip', 'class M {}');
		// Unterminated character class — EReg construction throws. The
		// arg-validation path catches it before any FS apply and exits
		// EXIT_USAGE (2) with a stderr `--regex: pattern[idx] "..." is
		// not a valid EReg: ...` line.
		final exit: Int = Cli.run(['strip', input, '--regex', '--replace', 'foo[', '--with', 'x']);
		Assert.equals(2, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripRegexDryRunCountsMatches(): Void {
		#if sys
		// Three calls to `new T<...>(` — regex `g` flag counts every one.
		final input: String = CliFixture.write(
			'apq_regex_strip', 'class M { var a = new Foo<X>(1); var b = new Foo<Y>(2); var c = new Bar<Z>(3); }'
		);
		final exit: Int = Cli.run([
    'strip',               input, '--regex', '--dry-run',
'--replace', 'new \\w+<\\w+>\\(',  '--with',          '',
]);
		Assert.equals(0, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 1b. --regex on recon predict-strip ---

	public function testReconRegexRequiresPredictStrip(): Void {
		#if sys
		// `--regex` outside `--predict-strip` is a usage error — no
		// other mode in recon takes substitution patterns, so the flag
		// would be silently ignored otherwise. Surfacing it as USAGE
		// catches the user before they wonder why nothing happened.
		final exit: Int = Cli.run(['recon', '--regex']);
		Assert.equals(2, exit);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 2. sweep --save ---

	public function testSweepSaveCopiesSnapshot(): Void {
		#if sys
		// Round-trip: write a known snapshot to the default file, ask
		// sweep to --save it to a temp path, verify the bytes match.
		final fakeJson: String = '{"pass":1,"fail":2,"skipParse":3,"skipWrite":0,"skipConfig":0,"skipMalformed":0,"fixtures":[]}';
		final src: String = CliFixture.writeAs('apq_sweep_save_src', 'json', fakeJson);
		final dst: String = CliFixture.writeAs('apq_sweep_save_dst', 'json', '');
		// Force the empty dst to be missing so --save creates it fresh.
		FileSystem.deleteFile(dst);
		final exit: Int = Cli.run(['sweep', '--file', src, '--save', dst]);
		Assert.equals(0, exit);
		Assert.isTrue(FileSystem.exists(dst));
		Assert.equals(fakeJson, File.getContent(dst));
		FileSystem.deleteFile(src);
		FileSystem.deleteFile(dst);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepSaveMissingFileExitsRuntime(): Void {
		#if sys
		// Source snapshot doesn't exist → exit 1 before the copy.
		final missing: String = CliFixture.writeAs('apq_sweep_missing', 'json', '');
		FileSystem.deleteFile(missing);
		final dst: String = CliFixture.writeAs('apq_sweep_save_dst', 'json', '');
		FileSystem.deleteFile(dst);
		Assert.equals(1, Cli.run(['sweep', '--file', missing, '--save', dst]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 3. test-summary ---

	public function testTestSummaryParsesUtestTranscript(): Void {
		#if sys
		final transcript: String = '  testFoo: OK ...\n  testBar: OK .\n  testBaz: FAIL: expected 1\n  testQux: ERROR: NPE\n';
		final path: String = CliFixture.writeAs('apq_test_summary', 'log', transcript);
		Assert.equals(0, Cli.run(['test-summary', path]));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryMissingDefaultExitsUsage(): Void {
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

	// First-failure locus capture — parseTestSummary returns a structured
	// result so the counts and the locus shape can be asserted without a
	// stdout-capture round-trip through Cli.run.

	public function testTestSummaryFirstFailureCapturesClassAndLine(): Void {
		#if sys
		// utest 1.13.x FAILURE shape: `  testName: FAILURE F\n    line: N, <msg>`.
		// Class header sits one line above the test group at column 0.
		final transcript: String = 'FailProbe\n  testOk: OK .\n  testIntentionalFail: FAILURE F\n    line: 9, intentional\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		// `tests` is the OK-pass count (legacy contract — matches the
		// existing `N tests / F failures / E errors` semantics where N is
		// passes, not the run total).
		Assert.equals(1, r.tests);
		Assert.equals(1, r.assertions);
		Assert.equals(1, r.failures);
		Assert.equals(0, r.errors);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff != null) {
			Assert.equals('FailProbe', ff.className);
			Assert.equals('testIntentionalFail', ff.testName);
			Assert.equals(9, ff.line);
			Assert.equals('intentional', ff.message);
			Assert.isTrue(ff.kind == TestSummaryFailureKind.Fail);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryFirstErrorCapturesMessage(): Void {
		#if sys
		// utest ERROR shape: `  testName: ERROR E\n    <bare message>` —
		// no `line:` prefix, just the thrown payload. line stays -1.
		final transcript: String = 'FailProbe\n  testIntentionalError: ERROR E\n    intentional error\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(0, r.tests);
		Assert.equals(1, r.errors);
		Assert.equals(0, r.failures);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff != null) {
			Assert.isTrue(ff.kind == TestSummaryFailureKind.Error);
			Assert.equals(-1, ff.line);
			Assert.equals('intentional error', ff.message);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryFirstFailureOnlyCapturesFirst(): Void {
		#if sys
		// Mixed transcript with both FAILURE and ERROR — counters bump for
		// both, firstFailure stays on the earliest (FAILURE before ERROR
		// in source order).
		final transcript: String = 'ClassA\n  testOne: FAILURE F\n    line: 5, first\n  testTwo: ERROR E\n    second\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(1, r.failures);
		Assert.equals(1, r.errors);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff != null) {
			Assert.equals('testOne', ff.testName);
			Assert.isTrue(ff.kind == TestSummaryFailureKind.Fail);
			Assert.equals(5, ff.line);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryNoFailuresHasNullLocus(): Void {
		#if sys
		final transcript: String = '  testFoo: OK ...\n  testBar: OK .\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(2, r.tests);
		Assert.equals(4, r.assertions);
		Assert.isNull(r.firstFailure);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryFailureWithoutDetailDoesNotEatNextRow(): Void {
		#if sys
		// Two adjacent failures with NO detail row between them —
		// awaitingDetail must NOT silently consume the second fail's
		// header line.
		final transcript: String = 'ClassA\n  testOne: FAILURE F\n  testTwo: FAILURE F\n    line: 7, second\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(2, r.failures);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff != null) {
			Assert.equals('testOne', ff.testName);
			// No detail row followed testOne — line / message stay empty.
			Assert.equals(-1, ff.line);
			Assert.equals('', ff.message);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 4. recon --candidates ---

	public function testReconCandidatesMutexWithOtherModes(): Void {
		#if sys
		// Combinable-with-nothing guard — surfaces a usage error
		// instead of silently picking one mode.
		Assert.equals(2, Cli.run(['recon', '--candidates', 'foo', '--predict-strip', '--delete', 'x']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconCandidatesInvalidRegexExitsUsage(): Void {
		#if sys
		// EReg compile error reported with the same shape as strip --regex.
		Assert.equals(2, Cli.run(['recon', '--candidates', 'foo[']));
		#else
		Assert.pass('non-sys target');
		#end
	}

}
