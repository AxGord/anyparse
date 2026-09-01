package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
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
		#if (sys || nodejs)
		final input: String = CliFixture.write('apq_regex_strip', 'class M { var x = new Foo<A, B, C>(1); var y = new Bar<X>(2); }');
		final exit: Int = Cli.run([
			'strip',
			input,
			'--regex',
			'--replace',
			'new ([A-Z]\\w*)<[^>]+>\\(',
			'--with',
			'new $1('
		]);
		Assert.equals(0, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testStripRegexCompileErrorExitsUsage(): Void {
		#if (sys || nodejs)
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
		#if (sys || nodejs)
		// Three calls to `new T<...>(` — regex `g` flag counts every one.
		final input: String = CliFixture.write(
			'apq_regex_strip', 'class M { var a = new Foo<X>(1); var b = new Foo<Y>(2); var c = new Bar<Z>(3); }'
		);
		final exit: Int = Cli.run([
			    'strip',               input, '--regex', '--dry-run',
			'--replace', 'new \\w+<\\w+>\\(',  '--with',          ''
		]);
		Assert.equals(0, exit);
		FileSystem.deleteFile(input);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 1b. --regex on recon predict-strip ---

	public function testReconRegexRequiresPredictStrip(): Void {
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
		final transcript: String = '  testFoo: OK ...\n  testBar: OK .\n  testBaz: FAIL: expected 1\n  testQux: ERROR: NPE\n';
		final path: String = CliFixture.writeAs('apq_test_summary', 'log', transcript);
		Assert.equals(0, Cli.run(['test-summary', path]));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryMissingDefaultExitsUsage(): Void {
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		if (ff == null) return;
		Assert.equals('FailProbe', ff.className);
		Assert.equals('testIntentionalFail', ff.testName);
		Assert.equals(9, ff.line);
		Assert.equals('intentional', ff.message);
		Assert.isTrue(ff.kind == TestSummaryFailureKind.Fail);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryFirstErrorCapturesMessage(): Void {
		#if (sys || nodejs)
		// utest ERROR shape: `  testName: ERROR E\n    <bare message>` —
		// no `line:` prefix, just the thrown payload. line stays -1.
		final transcript: String = 'FailProbe\n  testIntentionalError: ERROR E\n    intentional error\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(0, r.tests);
		Assert.equals(1, r.errors);
		Assert.equals(0, r.failures);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff == null) return;
		Assert.isTrue(ff.kind == TestSummaryFailureKind.Error);
		Assert.equals(-1, ff.line);
		Assert.equals('intentional error', ff.message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryFirstFailureOnlyCapturesFirst(): Void {
		#if (sys || nodejs)
		// Mixed transcript with both FAILURE and ERROR — counters bump for
		// both, firstFailure stays on the earliest (FAILURE before ERROR
		// in source order).
		final transcript: String = 'ClassA\n  testOne: FAILURE F\n    line: 5, first\n  testTwo: ERROR E\n    second\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(1, r.failures);
		Assert.equals(1, r.errors);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff == null) return;
		Assert.equals('testOne', ff.testName);
		Assert.isTrue(ff.kind == TestSummaryFailureKind.Fail);
		Assert.equals(5, ff.line);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryNoFailuresHasNullLocus(): Void {
		#if (sys || nodejs)
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
		#if (sys || nodejs)
		// Two adjacent failures with NO detail row between them —
		// awaitingDetail must NOT silently consume the second fail's
		// header line.
		final transcript: String = 'ClassA\n  testOne: FAILURE F\n  testTwo: FAILURE F\n    line: 7, second\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(2, r.failures);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff == null) return;
		Assert.equals('testOne', ff.testName);
		// No detail row followed testOne — line / message stay empty.
		Assert.equals(-1, ff.line);
		Assert.equals('', ff.message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 4. recon --candidates ---

	public function testReconCandidatesMutexWithOtherModes(): Void {
		#if (sys || nodejs)
		// Combinable-with-nothing guard — surfaces a usage error
		// instead of silently picking one mode.
		Assert.equals(2, Cli.run(['recon', '--candidates', 'foo', '--predict-strip', '--delete', 'x']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconCandidatesInvalidRegexExitsUsage(): Void {
		#if (sys || nodejs)
		// EReg compile error reported with the same shape as strip --regex.
		Assert.equals(2, Cli.run(['recon', '--candidates', 'foo[']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	// The quiet reporter (`NeverShowSuccessResults`) emits NO row for a
	// passing test, so a green transcript's only counts are utest's own
	// `assertations:` block and the runner's `tests executed:` line.

	public function testTestSummaryReadsQuietUtestSummaryBlock(): Void {
		#if (sys || nodejs)
		final transcript: String = 'tests executed: 4\n\nassertations: 12\nsuccesses: 12\nerrors: 0\nfailures: 0\n'
			+ 'warnings: 0\nexecution time: 1\n\nresults: ALL TESTS OK (success: true)\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(4, r.tests);
		Assert.equals(12, r.assertions);
		Assert.equals(0, r.failures);
		Assert.equals(0, r.errors);
		final h: Null<TestSummaryHeader> = r.header;
		Assert.notNull(h);
		if (h == null) return;
		Assert.isTrue(h.ok);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryHeaderOutranksRowDots(): Void {
		#if (sys || nodejs)
		// Red quiet run: the ONE failing test still prints its row, the 8
		// passing ones do not. The row dots would report 0 assertions; the
		// header's 9 is the real figure. Failure counts stay row-derived,
		// so `failures` counts the failing TEST, not utest's assertation.
		final transcript: String = 'tests executed: 9\nFoo\n  testBad: FAILURE F\n    line: 7, boom\n\nassertations: 9\nsuccesses: 8\n'
			+ 'errors: 0\nfailures: 1\nwarnings: 0\n\nresults: SOME TESTS FAILURES (success: false)\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(9, r.tests);
		Assert.equals(9, r.assertions);
		Assert.equals(1, r.failures);
		Assert.equals(0, r.errors);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryExecutedLineTakesTheLastMatch(): Void {
		#if (sys || nodejs)
		// A failing test's buffered stdout is flushed into the same stream
		// AHEAD of the runner's own line, so a transcript that merely quotes
		// the phrase must not outrank it.
		final transcript: String = 'tests executed: 999\nsome test chatter\ntests executed: 4\n\nassertations: 12\nsuccesses: 12\n'
			+ 'errors: 0\nfailures: 0\nwarnings: 0\n\nresults: ALL TESTS OK (success: true)\n';
		Assert.equals(4, Cli.parseTestSummary(transcript).tests);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryUncountableTranscriptExitsRuntime(): Void {
		#if (sys || nodejs)
		// No header, no `tests executed:` line, no result row — the run died
		// before its report. `0 tests / 0 assertions` read exactly like a
		// clean count to every reader, so this is an error, not a shrug.
		final path: String = CliFixture.writeAs('apq_test_summary_junk', 'log', 'build noise\nnothing countable here\n');
		Assert.equals(1, Cli.run(['test-summary', path]));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryAllZeroReportIsCountable(): Void {
		#if (sys || nodejs)
		// A REPORT that says zero is an answer. Every count here is 0 and the run
		// is countable because utest's block is present — the refusal asks whether
		// a report was found, never whether its numbers are zero. An all-zero test
		// passes this one vacuously; only a `counted` derived from the numbers
		// flips it.
		final transcript: String = 'tests executed: 0\n\nassertations: 0\nsuccesses: 0\nerrors: 0\nfailures: 0\n'
			+ 'warnings: 0\n\nresults: ALL TESTS OK (success: true)\n';
		final path: String = CliFixture.writeAs('apq_test_summary_zero', 'log', transcript);
		Assert.isTrue(Cli.parseTestSummary(transcript).counted);
		Assert.equals(0, Cli.run(['test-summary', path]));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryEmptyTinkRunIsCountable(): Void {
		#if (sys || nodejs)
		// tink_testrunner emits no utest header, so `counted` cannot come from
		// one — reaching that parser at all is the report, and a suite that ran
		// nothing prints its summary line with four zeros. An all-zero refusal
		// condition rejected this outright: rc 1, "the run died before printing
		// its report", on a transcript whose last line IS the report.
		final transcript: String = 'Suite:\n  case: [OK]\n\n0 Assertions 0 Success 0 Failures 0 Errors\n';
		final path: String = CliFixture.writeAs('apq_test_summary_tink_zero', 'log', transcript);
		Assert.isTrue(Cli.parseTestSummary(transcript).counted);
		Assert.equals(0, Cli.run(['test-summary', path]));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTestSummaryExecutedLineWithoutAHeaderIsNotTrusted(): Void {
		#if (sys || nodejs)
		// The runner prints `tests executed:` immediately before utest's block,
		// after every test's output — so the line without the block is not the
		// runner's. A run that died after a failing test whose flushed stdout
		// carried the phrase reported `999 tests` at exit 0; the count now falls
		// back to the rows, and the failure the transcript DOES carry survives.
		final transcript: String = 'SomeClass\n  testBad: FAILURE F\n    line: 3, boom\ntests executed: 999\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(0, r.tests);
		Assert.equals(1, r.failures);
		Assert.isTrue(r.counted);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
