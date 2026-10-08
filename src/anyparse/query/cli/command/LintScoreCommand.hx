package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.LintScore.LintScoreResult;
import anyparse.query.cli.CliContext;
import anyparse.query.format.json.LintFindingJson;
import anyparse.query.format.json.LintTruthJson;
import haxe.Exception;

using StringTools;

/**
 * `apq lint-score` — score a lint report against a ground-truth file (`LintScore`).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class LintScoreCommand implements CliCommand {

	private static inline final UNLABELLED_LIMIT: Int = 20;

	public function new() {}

	public function name(): String {
		return 'lint-score';
	}

	public function summary(): String {
		return 'Score a lint --format json report against a ground-truth file (precision, recall)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runLintScore(args);
	}

	public function usage(): Void {
		printLintScoreUsage();
	}

	#if (sys || nodejs)
	/**
	 * `apq lint-score --truth <truth.json> <report.json>`: 0 when every recall entry is still found, 1 when one is lost,
	 * 2 when the score could not be taken (a file missing or malformed, a truth file `LintScore.validate` refuses, a
	 * flag wrong) — distinct, so a gate that expects movement can never take a broken truth file for a pass.
	 */
	private static function runLintScore(args: Array<String>): Int {
		var truthPath: Null<String> = null;
		var reportPath: Null<String> = null;
		var severity: Null<String> = 'warning';
		var format: String = 'text';
		var limit: Int = UNLABELLED_LIMIT;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--truth':
					truthPath = CliArgs.expectValue(args, ++i, '--truth');
				case '--severity':
					final level: String = CliArgs.expectValue(args, ++i, '--severity');
					if (!['error', 'warning', 'info', 'all'].contains(level)) {
						CliIo.stderr('apq lint-score: unknown --severity value "$level" (expected error|warning|info|all)\n');
						return EXIT_USAGE;
					}
					severity = level == 'all' ? null : level;
				case '--format':
					format = CliArgs.expectValue(args, ++i, '--format');
					if (format != 'text' && format != 'json') {
						CliIo.stderr('apq lint-score: unknown --format value "$format" (expected text|json)\n');
						return EXIT_USAGE;
					}
				case '--limit':
					limit = Std.parseInt(CliArgs.expectValue(args, ++i, '--limit')) ?? UNLABELLED_LIMIT;
				case '--lang':
					// the hxq shim injects --lang haxe; a score reads two JSON files and needs no grammar
					CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printLintScoreUsage();
					return EXIT_OK;
				case _ if (!a.startsWith('--') && reportPath == null):
					reportPath = a;
				case _:
					CliIo.stderr('apq lint-score: unexpected argument "$a"\n');
					printLintScoreUsage();
					return EXIT_USAGE;
			}
			i++;
		}
		if (truthPath == null || reportPath == null) {
			CliIo.stderr('apq lint-score: both --truth <truth.json> and <report.json> are required\n');
			printLintScoreUsage();
			return EXIT_USAGE;
		}
		final truthFile: String = truthPath;
		final reportFile: String = reportPath;
		var result: Null<LintScoreResult> = null;
		try {
			final truth: LintTruthJson = LintScore.parseTruth(CliIo.readFile(truthFile));
			final findings: Array<LintFindingJson> = LintScore.parseFindings(CliIo.readFile(reportFile));
			result = LintScore.score(truth, findings, severity);
		} catch (exception: Exception) {
			CliIo.stderr('apq lint-score: cannot score $reportFile against $truthFile: ${exception.message}\n');
			return EXIT_USAGE;
		}
		if (result == null) throw new Exception('apq lint-score: the score neither produced a result nor threw');
		if (format == 'json')
			CliIo.sysPrint('${LintScore.json(result)}\n')
		else
			for (line in LintScore.render(result, limit)) CliIo.sysPrint('$line\n');
		return result.lost.length == 0 ? EXIT_OK : EXIT_RUNTIME;
	}

	private static function printLintScoreUsage(): Void {
		CliIo.sysPrint('Usage: apq lint-score --truth <truth.json> <report.json> [--severity <s>] [--format text|json] [--limit <n>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Score an `apq lint --format json` report (a bare array, or the --explain-long\n');
		CliIo.sysPrint('envelope) against a ground-truth file. Findings of the truth\'s rule meet its\n');
		CliIo.sysPrint('entries by KEY — (family, function, subject) of the finding\'s `data` — never by\n');
		CliIo.sysPrint('message or line; several findings with one key are one hit plus duplicates.\n');
		CliIo.sysPrint('Per family and overall: findings, keys, keys per verdict, unlabelled keys,\n');
		CliIo.sysPrint('precision = real-long keys / keys with a known verdict (unknown and unlabelled\n');
		CliIo.sysPrint('aside) and recall = recall entries hit / recall entries (real-long, or\n');
		CliIo.sysPrint('recall: true); then every lost recall entry and the unlabelled keys.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Truth file: {"rule", "project", "commit", "entries": [{"family", "function",\n');
		CliIo.sysPrint('"subject", "verdict": real-long|real-short|rare|false|dup-of|unknown,\n');
		CliIo.sysPrint('"dupOf" (dup-of only), "recall": bool, "evidence": {"kind": measured|test|code,\n');
		CliIo.sysPrint('"ref", "ms"}, "note"}]} — an unknown verdict or evidence kind, a dup-of without\n');
		CliIo.sysPrint('dupOf, or a key labelled twice is refused.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Exit 0 when every recall entry is found, 1 when one is lost, 2 when the score\n');
		CliIo.sysPrint('could not be taken (a file missing or malformed, a truth file refused).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --truth <path>    The ground-truth file (required)\n');
		CliIo.sysPrint('  --severity <s>    Score only findings of this severity: error|warning|info|all\n');
		CliIo.sysPrint('                    (default warning)\n');
		CliIo.sysPrint('  --format <fmt>    text (default) or json\n');
		CliIo.sysPrint('  --limit <n>       Unlabelled keys listed in text (default 20; -1 lists all)\n');
		CliIo.sysPrint('  -h, --help        Show this help\n');
	}
	#end

}
