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
		return EXIT_OK;
	}

	private static function printTestSummaryUsage(): Void {
		CliIo.sysPrint('Usage: apq test-summary [<file> | -]\n');
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
	}
	#end

}
