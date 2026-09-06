package anyparse.query.cli.command;

import anyparse.query.Cli.TestSummaryFailureKind;
import anyparse.query.Cli.TestSummaryFailureLocus;
import anyparse.query.Cli.TestSummaryResult;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using Lambda;

/**
 * `apq test-summary` — parse utest stdout transcript into tests/assertions/failures.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class TestSummaryCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'test-summary';
	}

	public function summary(): String {
		return 'Parse utest stdout transcript into tests/assertions/failures';
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
	 * the manual `grep -cE ': OK' /tmp/test.out` + assertion-count
	 * one-liner I keep rebuilding after every test run.
	 *
	 * Source resolution: positional path (file), `-` (stdin), or default
	 * `/tmp/test.out` when run with no positional and the file exists.
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
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '-h', '--help':
					printTestSummaryUsage();
					return EXIT_OK;
				case '--lang':
					// Shim invariance — apq test-summary doesn't use a plugin.
					CliArgs.expectValue(args, ++i, '--lang');
				case '--exit-status':
					final rawStatus: String = CliArgs.expectValue(args, ++i, '--exit-status');
					exitStatus = Std.parseInt(rawStatus);
					if (exitStatus == null) {
						CliIo.stderr('apq test-summary: --exit-status wants an integer, got "$rawStatus"\n');
						return EXIT_USAGE;
					}
				case _:
					if (sourcePath != null) {
						CliIo.stderr('apq test-summary: only one positional source supported (got "$sourcePath" and "$a")\n');
						return EXIT_USAGE;
					}
					sourcePath = a;
			}
			i++;
		}
		final raw: String = try {
			switch (sourcePath) {
				case null: if (sys.FileSystem.exists('/tmp/test.out'))
					sys.io.File.getContent('/tmp/test.out');
				else {
					CliIo.stderr('apq test-summary: no source given and /tmp/test.out missing — pass <path> or `-` for stdin\n');
					return EXIT_USAGE;
				}
				case '-': CliIo.readStdin();
				case _: sys.io.File.getContent((sourcePath: String));
			}
		} catch (e: Exception) {
			CliIo.stderr('apq test-summary: read failed: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final result: TestSummaryResult = TestTranscript.parseTestSummary(raw);
		final src: String = sourcePath ?? '/tmp/test.out';
		CliIo.warnIfTestJsStale('test-summary');
		// A transcript that carries no REPORT is a read failure, not a green empty
		// run. `0 tests / 0 assertions / 0 failures / 0 errors` is what every quiet
		// utest log printed once the per-test rows went away, and it reads exactly
		// like "counted, fine" — the only reader that ever noticed was
		// `tools/suite-shard.sh`, and only because it happens to refuse a zero.
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
		final ff: Null<TestSummaryFailureLocus> = result.firstFailure;
		if (ff != null) {
			final classQual: String = ff.className.length > 0 ? '${ff.className}.' : '';
			final lineFrag: String = ff.line >= 0 ? '  line:${ff.line}' : '';
			final msgFrag: String = ff.message.length > 0 ? '  ${ff.message}' : '';
			final label: String = ff.kind == TestSummaryFailureKind.Error ? 'error' : 'failure';
			CliIo.sysPrint('first $label: $classQual${ff.testName}$lineFrag$msgFrag\n');
		}
		return exitStatus == null ? EXIT_OK : reconcileExitStatus((exitStatus: Int), result, src);
	}

	/**
	 * Reconcile a transcript against the exit status its RUNNER returned —
	 * `--exit-status <N>`, the only reader of which is `tools/suite-shard.sh`,
	 * one call per shard.
	 *
	 * A transcript is not self-validating. Counting it answers what it SAYS;
	 * it cannot answer whether the process that wrote it got to the end. The
	 * two disagreements this catches are the same defect pointing opposite
	 * ways, and each prints a report that reads GREEN on its own:
	 *
	 *  - exited non-zero, reports no failing test — the run died before
	 *    finishing (measured: a shard killed after one row summarised to
	 *    `1 tests / 1 assertions / 0 failures / 0 errors` at exit 0, and the
	 *    caller then added those counts to its total as if 3205 missing tests
	 *    had passed);
	 *  - exited zero, reports failures — the runner swallowed its own verdict.
	 *
	 * The counts line is still printed either way: a caller that parses it
	 * must keep getting it, and the disagreement is an EXTRA line plus a
	 * non-zero exit, never a withheld answer.
	 */
	private static function reconcileExitStatus(status: Int, result: TestSummaryResult, src: String): Int {
		final red: Int = result.failures + result.errors;
		// The whole contract in one line: a run exits non-zero exactly when its
		// report names a failing test. Written as the equivalence rather than as
		// two negated branches so the agreeing case is the guard and neither
		// disagreement has to be spelled twice.
		if ((status != 0) == (red > 0)) return EXIT_OK;
		if (status != 0) {
			CliIo.sysPrint(
				'exit-status disagreement: the run exited $status while its transcript reports 0 failures / 0 errors — '
				+ 'the report does not explain the exit (a run that died before finishing, a filter that matched nothing, '
				+ 'or a failure that never reached stdout) ($src)\n'
			);
			return EXIT_RUNTIME;
		}
		CliIo.sysPrint(
			'exit-status disagreement: the run exited 0 while its transcript reports '
			+ '${result.failures} failures / ${result.errors} errors ($src)\n'
		);
		return EXIT_RUNTIME;
	}

	private static function printTestSummaryUsage(): Void {
		CliIo.sysPrint('Usage: apq test-summary [<file> | -] [--exit-status <N>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Parse a utest stdout transcript and report tests / assertions / failures /\n');
		CliIo.sysPrint('errors. Source resolution:\n');
		CliIo.sysPrint('  <file>     — read from the given path\n');
		CliIo.sysPrint('  -          — read from stdin (heredoc / pipe / process subst.)\n');
		CliIo.sysPrint('  (default)  — `/tmp/test.out` if it exists, else usage error\n');
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
