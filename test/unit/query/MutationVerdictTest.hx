package unit.query;

import anyparse.query.Cli;
import anyparse.query.MutationVerdict;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Unit cover for `apq mutation-verdict` — the classifier `tools/mutation-check.sh`
 * used to carry as a second, untestable awk copy.
 *
 * Every case drives a hand-written utest transcript through the REAL
 * `Cli.parseTestSummary`, not through a stubbed `TestSummaryResult`: the two
 * halves fail together in practice, since every historical bug here was the
 * PARSER reading the wrong line rather than the classifier mis-ranking a
 * parsed result. Stubbing the parse would have let both regressions through.
 *
 * The transcripts are shaped like the real thing on purpose — utest emits its
 * header block LAST, after everything the tests printed to stdout, and the
 * per-class listing comes after that. Several cases exist only to pin that
 * ordering, because a classifier that reads the FIRST `results:` line looks
 * correct on a tidy fixture and reports a red run as SURVIVED on a real one.
 */
@:nullSafety(Strict)
class MutationVerdictTest extends Test {

	public function testGreenRunSurvives(): Void {
		final verdict: MutationVerdictResult = classify(transcript(0, 0, 0, true, [
			'unit.SampleTest',
			'  testOne: OK ..'
		]), '');
		Assert.equals('SURVIVED', label(verdict));
		Assert.equals('0 tests failed / 12 assertions', verdict.detail);
	}

	public function testRedRunWithNoExpectationsIsKilled(): Void {
		final verdict: MutationVerdictResult = classify(transcript(1, 0, 0, false, [
			'unit.SampleTest',
			'  testOne: OK ..',
			'  testTwo: FAILURE expected 1 but was 2'
		]), '');
		Assert.equals('KILLED', label(verdict));
		Assert.equals('1 tests failed / 12 assertions: unit.SampleTest.testTwo', verdict.detail);
	}

	public function testMatchedExpectationIsKilled(): Void {
		final verdict: MutationVerdictResult = classify(transcript(1, 0, 0, false, [
			'unit.SampleTest',
			'  testTwo: FAILURE expected 1 but was 2'
		]), 'SampleTest.testTwo');
		Assert.equals('KILLED', label(verdict));
	}

	public function testUnmatchedExpectationIsMismatch(): Void {
		final verdict: MutationVerdictResult = classify(transcript(1, 0, 0, false, [
			'unit.SampleTest',
			'  testTwo: FAILURE expected 1 but was 2'
		]), 'SampleTest.testNeverRan');
		Assert.equals('MISMATCH', label(verdict));
		Assert.stringContains('missing: SampleTest.testNeverRan', verdict.detail);
	}

	/**
	 * A wider blast radius still answers the question the track asks, so the
	 * unnamed failure is REPORTED and does not demote the verdict.
	 */
	public function testFailureBeyondTheExpectationsIsReportedNotPenalised(): Void {
		final verdict: MutationVerdictResult = classify(transcript(2, 0, 0, false, [
			'unit.SampleTest',
			'  testTwo: FAILURE expected 1 but was 2',
			'unit.OtherTest',
			'  testThree: FAILURE expected 3 but was 4'
		]), 'SampleTest.testTwo');
		Assert.equals('KILLED', label(verdict));
		Assert.stringContains('+extra: unit.OtherTest.testThree', verdict.detail);
	}

	/**
	 * utest's `ITestHandler` auto-adds `Warning('no assertions')` to a test
	 * that completes without asserting, and `ResultStats.isOk` counts that as
	 * red. A classifier scanning for FAILURE/ERROR rows sees none and reports
	 * the mutation SURVIVED — a false finding, and the one verdict this code
	 * exists never to get wrong.
	 */
	public function testWarningOnlyRunIsRedNotSurvived(): Void {
		final verdict: MutationVerdictResult = classify(transcript(0, 0, 1, false, [
			'unit.SampleTest',
			'  testOne: WARNING no assertions'
		]), '');
		Assert.equals('KILLED', label(verdict));
		Assert.stringContains('unit.SampleTest.testOne', verdict.detail);
	}

	/** A typo'd filter must be loud; silently it would read as a finding. */
	public function testNoTestsExecutedIsItsOwnVerdict(): Void {
		final verdict: MutationVerdictResult = classify(transcript(0, 0, 1, false, [
			'unit.SampleTest',
			'  testOne: WARNING',
			'    line: 0, No tests executed.'
		]), '');
		Assert.equals('NO-TESTS', label(verdict));
	}

	/**
	 * The header is found by SHAPE, not by the first `results:` line. utest
	 * emits the block LAST, so a test printing its own `results:` line lands
	 * AHEAD of the real one — and a green-looking impostor there would report
	 * a red run as SURVIVED.
	 */
	public function testResultsLinePrintedByATestDoesNotSpoofTheVerdict(): Void {
		final chatter: Array<String> = [
			'results: ALL TESTS OK (success: true)',
			'assertations: 999'
		];
		final verdict: MutationVerdictResult = classify(transcript(1, 0, 0, false, [
			'unit.SampleTest',
			'  testTwo: FAILURE expected 1 but was 2'
		], chatter), '');
		Assert.equals('KILLED', label(verdict));
		Assert.stringContains('/ 12 assertions', verdict.detail, 'the count comes from the real header, not the chatter');
	}

	/** A transcript cut short before utest's block cannot be judged at all. */
	public function testTranscriptWithoutAHeaderIsRunFail(): Void {
		final verdict: MutationVerdictResult = classify('unit.SampleTest\n  testOne: OK ..\n', '');
		Assert.equals('RUN-FAIL', label(verdict));
	}

	/** Red by the header, but nothing names what went red. */
	public function testRedHeaderWithNoParsedRowIsRunFail(): Void {
		final verdict: MutationVerdictResult = classify(transcript(1, 0, 0, false, []), '');
		Assert.equals('RUN-FAIL', label(verdict));
	}

	/** Expectations are trimmed and blanks dropped, as the manifest allows. */
	public function testBlankExpectationEntriesAreIgnored(): Void {
		final verdict: MutationVerdictResult = classify(transcript(1, 0, 0, false, [
			'unit.SampleTest',
			'  testTwo: FAILURE expected 1 but was 2'
		]), ' SampleTest.testTwo , ');
		Assert.equals('KILLED', label(verdict));
		Assert.isFalse(verdict.detail.indexOf('+extra') >= 0, 'a blank entry must not become an unmatched failure');
	}

	// ------------------------------------------------------------ fixtures

	private inline function label(verdict: MutationVerdictResult): String {
		return MutationVerdict.label(verdict.kind);
	}

	private function classify(raw: String, expectCsv: String): MutationVerdictResult {
		final expected: Array<String> = [
			for (part in expectCsv.split(',')) if (part.trim().length > 0) part.trim()
		];
		return MutationVerdict.classify(Cli.parseTestSummary(raw), expected);
	}

	/**
	 * A transcript in utest's real ORDER: whatever the tests printed, then the
	 * header block, then the per-class listing. `rows` is that listing;
	 * `chatter` is test stdout, which lands ahead of the header.
	 */
	private function transcript(failures: Int, errors: Int, warnings: Int, ok: Bool, rows: Array<String>, ?chatter: Array<String>): String {
		final lines: Array<String> = chatter != null ? chatter.copy() : [];
		lines.push('assertations: 12');
		lines.push('successes: 12');
		lines.push('errors: $errors');
		lines.push('failures: $failures');
		lines.push('warnings: $warnings');
		lines.push('execution time: 0.01');
		lines.push('');
		lines.push(ok ? 'results: ALL TESTS OK (success: true)' : 'results: FAILED (success: false)');
		for (row in rows) lines.push(row);
		return lines.join('\n') + '\n';
	}

}
