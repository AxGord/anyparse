package anyparse.query.cli.command;

import anyparse.query.MutationVerdict.MutationVerdictResult;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq mutation-verdict` — classify one utest transcript as KILLED/SURVIVED/… for mutation-check.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class MutationVerdictCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'mutation-verdict';
	}

	public function summary(): String {
		return 'Classify one utest transcript as KILLED/SURVIVED/… for mutation-check';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runMutationVerdict(args);
		#else
		CliIo.stderr('apq mutation-verdict: requires a sys target (file read)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printMutationVerdictUsage();
		#end
	}

	#if (sys || nodejs)
	/**
	 * `apq mutation-verdict <log> [--expect <csv>]` — classify one utest
	 * transcript for `tools/mutation-check.sh`, printing the verdict on the
	 * first line and the row detail on the second.
	 *
	 * Two lines rather than JSON on purpose: the caller is a shell script, and
	 * the point of the subcommand is that shell no longer has to PARSE anything.
	 * A JSON payload would just move the second parser from awk to `jq`.
	 *
	 * The exit code answers "could this be classified", not "what was the
	 * verdict": every verdict — `RUN-FAIL` included — exits 0, because it is a
	 * verdict. Only a usage error or an unreadable file is non-zero, which keeps
	 * the caller's `if ! out=$(…)` guard meaning what it says.
	 */
	private static function runMutationVerdict(args: Array<String>): Int {
		var logPath: Null<String> = null;
		var expectCsv: String = '';
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--expect':
					expectCsv = CliArgs.expectValue(args, ++i, '--expect');
				case '--lang':
					// hxq shim auto-injects --lang haxe; no grammar plugin is
					// involved in reading a transcript. Consume it, as lint-diff
					// and sweep do, to keep shim invariance.
					CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printMutationVerdictUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('-')) {
						CliIo.stderr('apq mutation-verdict: unknown option "$a"\n');
						printMutationVerdictUsage();
						return EXIT_USAGE;
					}
					if (logPath != null) {
						CliIo.stderr('apq mutation-verdict: only one transcript supported (got "$logPath" and "$a")\n');
						return EXIT_USAGE;
					}
					logPath = a;
			}
			i++;
		}
		if (logPath == null) {
			CliIo.stderr('apq mutation-verdict: no transcript given\n');
			printMutationVerdictUsage();
			return EXIT_USAGE;
		}
		final source: String = logPath;
		final raw: String = try CliIo.readFile(source) catch (exception: Exception) {
			CliIo.stderr('apq mutation-verdict: read failed: ${exception.message}\n');
			return EXIT_RUNTIME;
		}
		final expected: Array<String> = [
			for (part in expectCsv.split(',')) if (part.trim().length > 0) part.trim()
		];
		final verdict: MutationVerdictResult = MutationVerdict.classify(TestTranscript.parseTestSummary(raw), expected);
		CliIo.sysPrint('${MutationVerdict.label(verdict.kind)}\n');
		CliIo.sysPrint('${verdict.detail}\n');
		return EXIT_OK;
	}

	private static function printMutationVerdictUsage(): Void {
		CliIo.sysPrint('Usage: apq mutation-verdict <transcript> [--expect <csv>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Classify one utest stdout transcript for tools/mutation-check.sh.\n');
		CliIo.sysPrint('Prints the verdict on line 1 and the report-row detail on line 2:\n');
		CliIo.sysPrint('  KILLED    the run went red and every expectation matched something\n');
		CliIo.sysPrint('  SURVIVED  the run was GREEN by utest own predicate (warnings count as red)\n');
		CliIo.sysPrint('  MISMATCH  the run went red, but some expectation matched nothing\n');
		CliIo.sysPrint('  NO-TESTS  the filter matched no test class\n');
		CliIo.sysPrint('  RUN-FAIL  no usable transcript, or a red run whose rows did not parse\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The exit code says whether classification was possible, not what the\n');
		CliIo.sysPrint('verdict was: every verdict exits 0, a usage error or unreadable file 2.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --expect <csv>  Comma-separated substrings matched against the failing\n');
		CliIo.sysPrint('                  test names; empty means any red run kills\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}
	#end

}
