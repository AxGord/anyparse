package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.LintScore.LintScoreResult;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.UsageFailure;
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

	/** The least severity a score counts unless told otherwise: warnings and errors, the output a reader acts on. */
	private static inline final DEFAULT_SEVERITY: String = 'warning';

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
	 * 2 when the score could not be taken (a file missing or malformed, a truth file `LintScore.validate` refuses, no finding
	 * left to score, a flag wrong) — distinct, so a gate that expects movement can never take a broken truth file for a pass.
	 */
	private static function runLintScore(args: Array<String>): Int {
		final o: Null<ScoreOpts> = parseScoreArgs(args);
		if (o == null) return EXIT_OK;
		final truthFile: String = o.truth;
		final reportFile: String = o.report;
		final severity: Null<String> = o.severity;
		var result: Null<LintScoreResult> = null;
		try {
			final truth: LintTruthJson = LintScore.parseTruth(CliIo.readFile(truthFile));
			final findings: Array<LintFindingJson> = LintDiff.parseReport(CliIo.readFile(reportFile));
			result = LintScore.score(truth, findings, severity);
		} catch (exception: Exception) {
			CliIo.stderr('apq lint-score: cannot score $reportFile against $truthFile: ${exception.message}\n');
			return EXIT_USAGE;
		}
		if (result == null) throw new Exception('apq lint-score: the score neither produced a result nor threw');
		if (result.excluded > 0)
			CliIo.stderr('apq lint-score: ${result.excluded} finding(s) of rule "${result.rule}" below ${severity ?? ''} left unscored\n');
		if (o.format == 'json')
			CliIo.sysPrint('${LintScore.json(result)}\n')
		else
			for (line in LintScore.render(result, o.limit)) CliIo.sysPrint('$line\n');
		return result.lost.length == 0 ? EXIT_OK : EXIT_RUNTIME;
	}

	/** The options `args` spell, or null after printing the help; a usage error throws (`UsageFailure`). */
	private static function parseScoreArgs(args: Array<String>): Null<ScoreOpts> {
		var truthPath: Null<String> = null;
		var reportPath: Null<String> = null;
		var severity: Null<String> = DEFAULT_SEVERITY;
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
					if (level != LintScore.ALL_SEVERITIES && !LintScore.SEVERITY_RANKS.contains(level))
						throw new UsageFailure('unknown --severity value "$level" (expected error|warning|info|all)');
					severity = level == LintScore.ALL_SEVERITIES ? null : level;
				case '--format':
					format = CliArgs.expectValue(args, ++i, '--format');
					if (format != 'text' && format != 'json')
						throw new UsageFailure('unknown --format value "$format" (expected text|json)');
				case '--limit':
					final value: String = CliArgs.expectValue(args, ++i, '--limit');
					final parsed: Null<Int> = Std.parseInt(value);
					if (parsed == null || '$parsed' != value || parsed < -1)
						throw new UsageFailure('--limit expects a count, or -1 for every unlabelled key — got "$value"');
					limit = parsed;
				case '--lang':
					// the hxq shim injects --lang haxe; a score reads two JSON files and needs no grammar
					CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printLintScoreUsage();
					return null;
				case _ if (!a.startsWith('-') && reportPath == null):
					reportPath = a;
				case _:
					throw new UsageFailure('lint-score: unexpected argument "$a" — see apq lint-score --help');
			}
			i++;
		}
		if (truthPath == null || reportPath == null) throw new UsageFailure('lint-score needs both --truth <truth.json> and <report.json>');
		return {
			truth: truthPath,
			report: reportPath,
			severity: severity,
			format: format,
			limit: limit
		};
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
		CliIo.sysPrint('aside; a dup-of key counts against it — a duplicate warning is output too) and\n');
		CliIo.sysPrint('recall = recall entries hit / recall entries (every real-long entry, plus any\n');
		CliIo.sysPrint('other marked recall: true); then every lost recall entry and the unlabelled keys.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Truth file: {"rule", "project", "commit" (all non-empty), "entries": [{"family",\n');
		CliIo.sysPrint('"function", "subject", "verdict": real-long|real-short|rare|false|dup-of|unknown,\n');
		CliIo.sysPrint('"dupOf": "family|function|subject" of another entry (dup-of only), "recall": bool\n');
		CliIo.sysPrint('(false is refused on real-long), "evidence": {"kind": measured|test|code, "ref",\n');
		CliIo.sysPrint('"ms" >= 0}, "note"}]}. A key labelled twice is refused too.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Exit 0 when every recall entry is found, 1 when one is lost, 2 when the score\n');
		CliIo.sysPrint('could not be taken: a file missing or malformed, a truth file refused, or no\n');
		CliIo.sysPrint('finding of the rule left to score (a misspelt rule, an empty report, a severity\n');
		CliIo.sysPrint('that excludes them all).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --truth <path>    The ground-truth file (required)\n');
		CliIo.sysPrint('  --severity <s>    Score findings at <s> or above: error|warning|info, or all\n');
		CliIo.sysPrint('                    (default warning: warnings and errors)\n');
		CliIo.sysPrint('  --format <fmt>    text (default) or json\n');
		CliIo.sysPrint('  --limit <n>       Unlabelled keys listed in text (default 20; -1 lists all)\n');
		CliIo.sysPrint('  -h, --help        Show this help\n');
	}
	#end

}

/** The options of one `apq lint-score` run. */
private typedef ScoreOpts = {
	final truth: String;
	final report: String;
	final severity: Null<String>;
	final format: String;
	final limit: Int;
}
