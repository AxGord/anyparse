package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
import anyparse.query.Cli.TestSummaryFailureKind;
import anyparse.query.Cli.TestSummaryFailureLocus;
import anyparse.query.Cli.TestSummaryResult;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `apq test-summary` — tink_testrunner (tink_unittest) transcript support.
 *
 * TM's unit suite (`openfl test macos -DUNIT_TESTS`) runs on
 * tink_unittest/tink_testrunner, not utest — `Cli.parseTestSummary` only
 * recognized the utest `  testName: OK ...` shape, so a tink transcript
 * silently parsed to `0 tests / 0 assertions / 0 failures / 0 errors`
 * (reproduced against real TM logs, with and without ANSI stripped —
 * the line SHAPE never matched, ANSI was never the blocker).
 *
 * Fixture bytes are hand-built (not copied from the real TM log) to
 * mirror `tink_testrunner`'s `BasicReporter`/`AnsiFormatter`
 * (haxelib tink_testrunner 0.9.0, src/tink/testrunner/Reporter.hx)
 * byte-for-byte:
 *  - Suite header (0-indent): `<y>Name<r>: <c>[file:line]<r>`
 *  - Case header (2-indent): `<y>  desc<r>: <c>[file:line] <r>`
 *  - Assertion (4-indent, dashed): `- <g>[OK]<r> <c>[file:line]<r> desc`
 *    or `- <red>[FAIL]<r> <c>[file:line]<r> desc`
 *  - Assertion failure detail (8-indent, no dash): `<red>message<r>`
 *  - Case-level throw (4-indent, dashed, no brackets): `- <red>message<r>`
 *  - Final summary (0-indent): `<g|red>N Assertion(s)   N Success   N
 *    Failure(s)   N Error(s)   <r>` — confirmed against a real green
 *    TM run: `1111 Assertions   1111 Success   0 Failure   0 Error   `.
 * `<y>`=yellow(33) `<c>`=cyan(36) `<g>`=green(32) `<red>`=red(31)
 * `<r>`=reset(39).
 */
@:nullSafety(Strict)
class ApqTestSummaryTinkTest extends Test {

	static inline final ESC: String = "\x1b";

	private static function ansi(code: String, text: String): String {
		return '${ESC}[${code}m$text${ESC}[39m';
	}

	private static function suiteHeader(name: String, path: String, line: Int): String {
		return '${ansi('33', name)}: ${ansi('36', '[$path:$line]')}';
	}

	private static function caseHeader(desc: String, path: String, line: Int): String {
		return '${ansi('33', '  $desc')}: ${ansi('36', '[$path:$line] ')}';
	}

	private static function assertRow(ok: Bool, path: String, line: Int, desc: String): String {
		final tag: String = ok ? ansi('32', '[OK]') : ansi('31', '[FAIL]');
		return '    - $tag ${ansi('36', '[$path:$line]')} $desc';
	}

	private static function failDetail(msg: String): String {
		return ansi('31', '        $msg');
	}

	private static function caseThrow(msg: String): String {
		return ansi('31', '    - $msg');
	}

	private static function summaryLine(total: Int, success: Int, failures: Int, errors: Int): String {
		final ok: Bool = failures == 0 && errors == 0;
		final assertWord: String = total > 1 ? 'Assertions' : 'Assertion';
		final failWord: String = failures > 1 ? 'Failures' : 'Failure';
		final errWord: String = errors > 1 ? 'Errors' : 'Error';
		final text: String = '$total $assertWord   $success Success   $failures $failWord   $errors $errWord   ';
		return ansi(ok ? '32' : '31', text);
	}

	// --- All-passing transcript, ANSI-colored (the real TM shape) ---

	public function testTinkAllPassingTranscriptParsed(): Void {
		#if (sys || nodejs)
		final lines: Array<String> = [
			suiteHeader('SampleWatcherTest', 'src/tests/unit/SampleWatcherTest.hx', 17),
			caseHeader('locks are released after update', 'src/tests/unit/SampleWatcherTest.hx', 43),
			assertRow(true, 'src/tests/unit/SampleWatcherTest.hx', 55, 'Expected exactly one record'),
			caseHeader('save creates the file', 'src/tests/unit/SampleWatcherTest.hx', 60),
			assertRow(true, 'src/tests/unit/SampleWatcherTest.hx', 69, 'Path should round-trip'),
			assertRow(true, 'src/tests/unit/SampleWatcherTest.hx', 70, 'File should exist'),
			suiteHeader('SampleStoreTest', 'src/tests/unit/SampleStoreTest.hx', 15),
			caseHeader('put persists via the IO worker', 'src/tests/unit/SampleStoreTest.hx', 20),
			assertRow(true, 'src/tests/unit/SampleStoreTest.hx', 28, 'IO queue must drain'),
			'',
			summaryLine(4, 4, 0, 0),
			'',
			'Tests completed - watchdog thread will exit gracefully',
		];
		final r: TestSummaryResult = Cli.parseTestSummary(lines.join('\n'));
		Assert.equals(4, r.assertions);
		Assert.equals(0, r.failures);
		Assert.equals(0, r.errors);
		// 3 case blocks total, all passing.
		Assert.equals(3, r.tests);
		Assert.isNull(r.firstFailure);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Same transcript, ANSI stripped by hand before parsing: parser must
	// still see the tink shape (proves the format regexes, not ANSI
	// stripping, were the original blocker). ---

	public function testTinkAllPassingTranscriptParsedWithoutAnsi(): Void {
		#if (sys || nodejs)
		final esc: EReg = new EReg('${ESC}\\[[0-9;]*m', 'g');
		final lines: Array<String> = [
			suiteHeader('SampleWatcherTest', 'src/tests/unit/SampleWatcherTest.hx', 17),
			caseHeader('locks are released after update', 'src/tests/unit/SampleWatcherTest.hx', 43),
			assertRow(true, 'src/tests/unit/SampleWatcherTest.hx', 55, 'Expected exactly one record'),
			summaryLine(1, 1, 0, 0),
		];
		final plain: String = esc.replace(lines.join('\n'), '');
		// Sanity: the ESC bytes are really gone.
		Assert.equals(-1, plain.indexOf(ESC));
		final r: TestSummaryResult = Cli.parseTestSummary(plain);
		Assert.equals(1, r.assertions);
		Assert.equals(0, r.failures);
		Assert.equals(1, r.tests);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Plain (never-ANSI) tink transcript: BasicFormatter output (no
	// tty / `ansi` extension disabled) uses the identical bracket/dash
	// shape with no escape codes at all — must auto-detect too. ---

	public function testTinkPlainNonAnsiTranscriptDetected(): Void {
		#if (sys || nodejs)
		final transcript: String = 'SampleTest: [src/tests/unit/SampleTest.hx:5]\n'
			+ '  does the thing: [src/tests/unit/SampleTest.hx:9] \n' + '    - [OK] [src/tests/unit/SampleTest.hx:11] ok\n'
			+ '    - [OK] [src/tests/unit/SampleTest.hx:12] ok\n' + '2 Assertions   2 Success   0 Failure   0 Error   \n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(2, r.assertions);
		Assert.equals(0, r.failures);
		Assert.equals(1, r.tests);
		Assert.isNull(r.firstFailure);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Assertion failure: firstFailure locus + message from the
	// dedicated failure-detail row. ---

	public function testTinkAssertionFailureCapturesLocus(): Void {
		#if (sys || nodejs)
		final lines: Array<String> = [
			suiteHeader('SampleGateTest', 'src/tests/unit/SampleGateTest.hx', 8),
			caseHeader('rejects an out-of-range value', 'src/tests/unit/SampleGateTest.hx', 12),
			assertRow(true, 'src/tests/unit/SampleGateTest.hx', 14, 'setup ok'),
			assertRow(false, 'src/tests/unit/SampleGateTest.hx', 16, 'value should be rejected'),
			failDetail('expected false but got true'),
			summaryLine(2, 1, 1, 0),
		];
		final r: TestSummaryResult = Cli.parseTestSummary(lines.join('\n'));
		Assert.equals(2, r.assertions);
		Assert.equals(1, r.failures);
		Assert.equals(0, r.errors);
		// The failed case must not count toward the passing-test tally.
		Assert.equals(0, r.tests);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff != null) {
			Assert.equals('SampleGateTest', ff.className);
			Assert.equals('rejects an out-of-range value', ff.testName);
			Assert.equals(16, ff.line);
			Assert.equals('expected false but got true', ff.message);
			Assert.isTrue(ff.kind == TestSummaryFailureKind.Fail);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Only the FIRST failure across multiple is captured; counters
	// keep bumping for the rest. ---

	public function testTinkOnlyFirstFailureLocusCaptured(): Void {
		#if (sys || nodejs)
		final lines: Array<String> = [
			suiteHeader('SampleGateTest', 'src/tests/unit/SampleGateTest.hx', 8),
			caseHeader('case one', 'src/tests/unit/SampleGateTest.hx', 12),
			assertRow(false, 'src/tests/unit/SampleGateTest.hx', 14, 'first failure'),
			failDetail('boom one'),
			caseHeader('case two', 'src/tests/unit/SampleGateTest.hx', 20),
			assertRow(false, 'src/tests/unit/SampleGateTest.hx', 22, 'second failure'),
			failDetail('boom two'),
			summaryLine(2, 0, 2, 0),
		];
		final r: TestSummaryResult = Cli.parseTestSummary(lines.join('\n'));
		Assert.equals(2, r.failures);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff != null) {
			Assert.equals('case one', ff.testName);
			Assert.equals('boom one', ff.message);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Case-level throw (no assertion row at all — `CaseResultType.
	// Failed(e)`) buckets as an ERROR, not a failure, per tink_testrunner's
	// own `summary()` classification (AssertionFailed -> failures,
	// everything else -> errors). ---

	public function testTinkCaseLevelThrowCountsAsError(): Void {
		#if (sys || nodejs)
		final lines: Array<String> = [
			suiteHeader('SampleSetupTest', 'src/tests/unit/SampleSetupTest.hx', 3),
			caseHeader('throws before any assertion', 'src/tests/unit/SampleSetupTest.hx', 6),
			caseThrow('Null Object Reference'),
			summaryLine(0, 0, 0, 1),
		];
		final r: TestSummaryResult = Cli.parseTestSummary(lines.join('\n'));
		Assert.equals(0, r.failures);
		Assert.equals(1, r.errors);
		Assert.equals(0, r.tests);
		final ff: Null<TestSummaryFailureLocus> = r.firstFailure;
		Assert.notNull(ff);
		if (ff != null) {
			Assert.equals('throws before any assertion', ff.testName);
			Assert.equals('Null Object Reference', ff.message);
			Assert.isTrue(ff.kind == TestSummaryFailureKind.Error);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Pin against the exact real-log summary-line text observed in a
	// green TM run (`/tmp/tm-unit-tests.txt`, `/tmp/tm-unit-tests-2.txt`):
	// `1111 Assertions   1111 Success   0 Failure   0 Error   `. Numbers
	// only — no TM class/test names, to keep the fixture generic. ---

	public function testTinkRealSummaryLineShapePinned(): Void {
		#if (sys || nodejs)
		final real: String = ansi('32', '1111 Assertions   1111 Success   0 Failure   0 Error   ');
		final transcript: String = suiteHeader('SampleFinalTest', 'src/tests/unit/SampleFinalTest.hx', 1) + '\n'
			+ caseHeader('trivial', 'src/tests/unit/SampleFinalTest.hx', 2) + '\n'
			+ assertRow(true, 'src/tests/unit/SampleFinalTest.hx', 3, 'ok') + '\n' + real + '\n'
			+ 'Tests completed - watchdog thread will exit gracefully\n' + 'Stopping FileSystem background threads...\n'
			+ 'FileSystem stopped\n' + 'EXIT=0\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(1111, r.assertions);
		Assert.equals(1111, r.assertions); // Success mirrors assertions in an all-green run
		Assert.equals(0, r.failures);
		Assert.equals(0, r.errors);
		Assert.isNull(r.firstFailure);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- CLI wiring: `apq test-summary <file>` still exits 0 on a tink
	// transcript (informational parse, same contract as the utest path). ---

	public function testTinkTranscriptViaCliExitsOk(): Void {
		#if (sys || nodejs)
		final lines: Array<String> = [
			suiteHeader('SampleCliTest', 'src/tests/unit/SampleCliTest.hx', 1),
			caseHeader('case', 'src/tests/unit/SampleCliTest.hx', 2),
			assertRow(true, 'src/tests/unit/SampleCliTest.hx', 3, 'ok'),
			summaryLine(1, 1, 0, 0),
		];
		final path: String = CliFixture.writeAs('apq_test_summary_tink', 'log', lines.join('\n'));
		Assert.equals(0, Cli.run(['test-summary', path]));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Regression pin: a utest transcript (no tink markers anywhere)
	// must still take the utest path — auto-detection must not
	// misclassify it. ---

	public function testUtestTranscriptStillTakesUtestPath(): Void {
		#if (sys || nodejs)
		final transcript: String = '  testFoo: OK ...\n  testBar: OK .\n  testBaz: FAIL: expected 1\n';
		final r: TestSummaryResult = Cli.parseTestSummary(transcript);
		Assert.equals(2, r.tests);
		Assert.equals(4, r.assertions);
		Assert.equals(1, r.failures);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
