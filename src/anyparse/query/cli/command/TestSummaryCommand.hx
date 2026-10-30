package anyparse.query.cli.command;

import anyparse.query.Cli.TestSummaryResult;
import anyparse.query.ExitCode.*;

/**
 * `apq test-summary` — parse utest stdout transcript into tests/assertions/failures.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class TestSummaryCommand implements CliCommand implements LanguageFree {

	/**
	 * Env var naming the transcript to read when no positional source is given.
	 *
	 * There is no PATH default any more, and there cannot be one. A transcript is written by a
	 * DIFFERENT process (`node bin/test.js > …`), so nothing this process knows about itself —
	 * its pid, its cwd — can name the file it is meant to read; the old `/tmp/test.out` named
	 * one file for the whole machine, and two workers each writing their own suite log there
	 * answered each other's questions — a transcript one had not written, at exit 0 with
	 * plausible counts, and in one round a TORN interleave that neither had written. An env
	 * var is the only thing that scales with the caller's own isolation, so it is the only
	 * default offered.
	 */
	private static inline final TRANSCRIPT_ENV: String = 'APQ_TEST_OUT';

	public function new() {}

	public function name(): String {
		return 'test-summary';
	}

	public function summary(): String {
		return 'Parse utest stdout transcript into tests/assertions/failures';
	}

	public function flags(): CliFlags {
		return new CliFlags([], ['--exit-status']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runTestSummary(args);
		#else
		CliIo.stderr('apq test-summary: requires a sys target (file or stdin read)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printTestSummaryUsage();
		#end
	}

	#if (sys || nodejs)
	/**
	 * `apq test-summary [<file>]` — parse a utest stdout transcript and
	 * print `N tests / M assertions / F failures / E errors`. Replaces
	 * the manual `grep -cE ': OK' <transcript>` + assertion-count one-liner I keep rebuilding after every test run.
	 *
	 * Source resolution: positional path (file), `-` (stdin), or `$TRANSCRIPT_ENV`
	 * when run with no positional. No positional and no env var is a USAGE error —
	 * see the constant for why a path default cannot exist here.
	 * Exits 0 on a COUNTABLE parse, 1 on a read failure or on a
	 * transcript that yields no counts at all (see the refusal in the body).
	 * The test outcome itself is informational — the runner's exit code is
	 * the authoritative pass/fail signal.
	 *
	 * Parse rules (utest 1.13.x format, what `node bin/test.js` emits):
	 *  - `  testName: OK <dots>` — one line per test; trailing dots are
	 *    one per assertion.
	 *  - `  testName: FAIL` / `  testName: ERROR` — failure / error
	 *    counters; case-insensitive substring match on the suffix.
	 */
	private static function runTestSummary(args: Array<String>): Int {
		var sourcePath: Null<String> = null;
		var exitStatus: Null<Int> = null;
		for (arg in new TestSummaryCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '-h', '--help':
					printTestSummaryUsage();
					return EXIT_OK;
				case '--lang':
					// Shim invariance — apq test-summary doesn't use a plugin.
					arg.value();
				case '--exit-status':
					final rawStatus: String = arg.value();
					exitStatus = Std.parseInt(rawStatus);
					if (exitStatus == null) {
						CliIo.stderr('apq test-summary: --exit-status wants an integer, got "$rawStatus"\n');
						return EXIT_USAGE;
					}
				case null:
					if (sourcePath != null) {
						CliIo.stderr('apq test-summary: only one positional source supported (got "$sourcePath" and "$a")\n');
						return EXIT_USAGE;
					}
					sourcePath = a;
			}
		}
		final resolved: Null<String> = sourcePath ?? Sys.getEnv(TRANSCRIPT_ENV);
		if (resolved == null || resolved.length == 0) {
			CliIo.stderr(
				'apq test-summary: no source given — pass <path>, `-` for stdin, or set $TRANSCRIPT_ENV to the transcript '
				+ 'this run wrote. There is no built-in default: the one that used to be here named a single machine-global '
				+ 'file, so a second worker\'s transcript answered the first worker\'s question at exit 0.\n'
			);
			return EXIT_USAGE;
		}
		final src: String = resolved;
		final raw: String = try {
			src == '-' ? CliIo.readStdin() : sys.io.File.getContent(src);
		} catch (e: Exception) {
			CliIo.stderr('apq test-summary: read failed: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final result: TestSummaryResult = TestTranscript.parseTestSummary(raw);
		CliIo.warnIfTestJsStale('test-summary');
		// A transcript that carries no REPORT is a read failure, not a green empty
		// run. `0 tests / 0 assertions / 0 failures / 0 errors` is what every quiet
		// utest log printed once the per-test rows went away, and it reads exactly
		// like "counted, fine" — the only reader that ever noticed was the shard runner, and only because it happens to refuse a zero.
		//
		// The question is whether a report was FOUND, never whether its numbers are
		// zero: utest's "No tests executed." run and a tink suite that ran nothing
		// (`0 Assertions 0 Success 0 Failures 0 Errors`) are both all-zero answers,
		// and an all-zero test refused the second one outright.
		if (!result.counted) {
			CliIo.stderr(
				'apq test-summary: no report found in "$src" — no utest header block, no result row, and no tink reporter output. '
				+ 'The run died before printing its report, or this is not a utest / tink transcript.\n'
			);
			return EXIT_RUNTIME;
		}
		CliIo.sysPrint(
			'${result.tests} tests / ${result.assertions} assertions / ${result.failures} failures / ${result.errors} errors  ($src)\n'
		);
		// utest synthesises the "No tests executed." row with an EMPTY method
		// name, so it parses as neither a test row nor a failure row: the counts
		// line for a filter that matched nothing reads all-zero, i.e. green.
		if (result.noTests) CliIo.sysPrint('no tests executed: the filter matched no test class\n');
		final locus: Null<String> = TestTranscript.firstFailureLine(result);
		if (locus != null) CliIo.sysPrint('$locus\n');
		return exitStatus == null ? EXIT_OK : reconcileExitStatus((exitStatus: Int), result, src);
	}

	/**
	 * Reconcile a transcript against the exit status its RUNNER returned (`--exit-status <N>`; the rule is
	 * `TestTranscript.exitStatusDisagreement`). The counts line is printed either way: a caller that parses it must keep
	 * getting it, and the disagreement is an EXTRA line plus a non-zero exit, never a withheld answer.
	 */
	private static function reconcileExitStatus(status: Int, result: TestSummaryResult, src: String): Int {
		final disagreement: Null<String> = TestTranscript.exitStatusDisagreement(status, result, src);
		if (disagreement == null) return EXIT_OK;
		CliIo.sysPrint('$disagreement\n');
		return EXIT_RUNTIME;
	}

	private static function printTestSummaryUsage(): Void {
		CliIo.sysPrint('Usage: apq test-summary [<file> | -] [--exit-status <N>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Parse a utest stdout transcript and report tests / assertions / failures /\n');
		CliIo.sysPrint('errors. Source resolution:\n');
		CliIo.sysPrint('  <file>     — read from the given path\n');
		CliIo.sysPrint('  -          — read from stdin (heredoc / pipe / process subst.)\n');
		CliIo.sysPrint('  (default)  — $$$TRANSCRIPT_ENV when set, else a usage error. There is no\n');
		CliIo.sysPrint('               path default: one machine-global file answered a second\n');
		CliIo.sysPrint('               worker with the first worker\'s transcript, at exit 0.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Assertions come from utest\'s own `assertations:` block when the transcript\n');
		CliIo.sysPrint('has one, and the test total from the runner\'s `tests executed:` line — the\n');
		CliIo.sysPrint('quiet reporter prints no row for a passing test. Without a header, both\n');
		CliIo.sysPrint('fall back to the `  testName: OK <dots>` rows (one dot per assertion).\n');
		CliIo.sysPrint('Failure / error counts are always row-derived, so they count TESTS.\n');
		CliIo.sysPrint('When any FAIL / ERROR is present, appends a second line with the first\n');
		CliIo.sysPrint('failure\'s locus: `first failure: ClassName.testName  line:N  <message>`\n');
		CliIo.sysPrint('(class header / line / message included when utest emitted them).\n');
		CliIo.sysPrint('Exits 0 on a countable parse and 1 on a transcript that yields no counts\n');
		CliIo.sysPrint('at all — the test runner\'s own exit code stays the authoritative\n');
		CliIo.sysPrint('pass/fail signal.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('--exit-status <N> hands over the exit status the runner actually returned\n');
		CliIo.sysPrint('and reconciles it with the transcript: a non-zero status with no failing\n');
		CliIo.sysPrint('test in the report (the run died before finishing), or a zero status with\n');
		CliIo.sysPrint('failures in it, prints an `exit-status disagreement:` line after the counts\n');
		CliIo.sysPrint('and exits 1. The counts line is printed either way.\n');
	}
	#end

}
