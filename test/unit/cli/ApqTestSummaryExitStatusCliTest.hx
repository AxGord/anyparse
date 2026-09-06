package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * `apq test-summary --exit-status <N>` — the transcript reconciled against
 * the exit status its RUNNER returned.
 *
 * Counting a transcript answers what it SAYS. It cannot answer whether the
 * process that wrote it reached the end, and that gap is what let a shard
 * runner print a green report over a red run. Measured on 2026-09-06 with a
 * test double that killed one of four shards after a single test row:
 *
 *   shard 0:  202 classes /     1 tests /      1 assertions / 0 failures / 0 errors (exit 1)
 *   --- suite-shard: 794 classes / 10928 tests / 38241 assertions / 1 failures / 0 errors ... ---
 *   parity: counts not cross-checked (class parity OK: 794 placed; ...)
 *
 * Every printed count is green, the aggregate is 3205 tests short of the
 * 14 133 the same tree produces intact, and stderr carried nothing at all:
 * `test-summary` parsed the one surviving `testName: OK .` row into
 * `1 tests / 1 assertions / 0 failures / 0 errors` and exited 0, so the
 * caller added a partial prefix to its total as though the missing tests had
 * passed. Only `(exit 1)` and the process exit code dissented.
 *
 * The two disagreements below are that defect pointing opposite ways, and
 * BOTH read as green on their own — a non-zero exit with nothing failing in
 * the report, and a zero exit with failures in it. The counts line is
 * asserted to survive either one: a caller that parses it must keep getting
 * it, so a disagreement is an extra line plus a non-zero exit, never a
 * withheld answer.
 *
 * `testTruncatedTranscriptWithoutTheFlagStillExitsOk` is the control that
 * keeps the rest from being tautological — it pins that the flag is what
 * buys the check, not some property of the fixture bytes.
 *
 * Three fixture transcripts: `TRUNCATED` is a run killed after one result row
 * (rows, no end-of-run report — the shape the shard double produced), while
 * `GREEN` and `RED` both carry utest's own block and differ only in the one row
 * and the counts in it.
 */
@:nullSafety(Strict)
class ApqTestSummaryExitStatusCliTest extends Test {

	private static final TRUNCATED: String = 'unit.runtime.SpanTest\n  testZeroWidthSpanToString: OK .\n';
	private static final GREEN: String =
		'  testA: OK ..\nassertations: 2\nsuccesses: 1\nerrors: 0\nfailures: 0\nwarnings: 0\nresults: (success: true)\ntests executed: 1\n';
	private static final RED: String = '  testA: FAIL: nope\nassertations: 2\nsuccesses: 0\nerrors: 0\nfailures: 1\nwarnings: 0\n'
		+ 'results: (success: false)\ntests executed: 1\n';

	/**
	 * KILLED by arm `M-EXIT-STATUS-AGREES`, which makes the reconciliation
	 * answer `EXIT_OK` whatever the two say — the exact state this slice
	 * found the tool in.
	 */
	@:pin('control')
	@:killer('M-EXIT-STATUS-AGREES')
	public function testTruncatedTranscriptDisagreesWithANonZeroExit(): Void {
		final out: String = runSummary(TRUNCATED, ['--exit-status', '137'], 1);
		#if nodejs
		Assert.stringContains('exit-status disagreement:', out);
		Assert.stringContains('the run exited 137', out);
		// The answer is never withheld: the counts line is still the caller's
		// best available reading of the transcript.
		Assert.stringContains('1 tests / 1 assertions / 0 failures / 0 errors', out);
		#end
	}

	public function testTruncatedTranscriptWithoutTheFlagStillExitsOk(): Void {
		final out: String = runSummary(TRUNCATED, [], 0);
		#if nodejs
		Assert.isFalse(out.indexOf('exit-status disagreement:') >= 0, 'no flag, no reconciliation: $out');
		#end
	}

	public function testGreenTranscriptAgreesWithAZeroExit(): Void {
		final out: String = runSummary(GREEN, ['--exit-status', '0'], 0);
		#if nodejs
		Assert.isFalse(out.indexOf('exit-status disagreement:') >= 0, 'green and exit 0 agree: $out');
		#end
	}

	public function testGreenTranscriptDisagreesWithANonZeroExit(): Void {
		final out: String = runSummary(GREEN, ['--exit-status', '1'], 1);
		#if nodejs
		Assert.stringContains('exit-status disagreement:', out);
		Assert.stringContains('1 tests / 2 assertions / 0 failures / 0 errors', out);
		#end
	}

	public function testRedTranscriptDisagreesWithAZeroExit(): Void {
		final out: String = runSummary(RED, ['--exit-status', '0'], 1);
		#if nodejs
		Assert.stringContains('the run exited 0 while its transcript reports 1 failures / 0 errors', out);
		#end
	}

	public function testRedTranscriptAgreesWithANonZeroExit(): Void {
		final out: String = runSummary(RED, ['--exit-status', '1'], 0);
		#if nodejs
		Assert.isFalse(out.indexOf('exit-status disagreement:') >= 0, 'red and exit 1 agree: $out');
		#end
	}

	public function testNonIntegerExitStatusIsAUsageError(): Void {
		final out: String = runSummary(GREEN, ['--exit-status', 'abc'], 2);
		#if nodejs
		// A usage error answers nothing about the transcript — no counts, no
		// verdict — so nothing it prints can be mistaken for a reading.
		Assert.equals('', out);
		#end
	}

	/**
	 * Run `apq test-summary <fixture> <extra…>`, assert the exit code, and
	 * answer what it printed. One helper because every case here differs only
	 * in the transcript, the flag and the expected code — and because a
	 * fixture path must be deleted on the way out of each of them.
	 */
	private function runSummary(transcript: String, extra: Array<String>, expected: Int): String {
		#if (sys || nodejs)
		final path: String = CliFixture.writeAs('apq_test_summary_exit_status', 'log', transcript);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['test-summary', path].concat(extra)));
		Assert.equals(expected, code);
		FileSystem.deleteFile(path);
		return out;
		#else
		Assert.pass('non-sys target');
		return '';
		#end
	}

}
