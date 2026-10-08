package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.LongLockExplain.LongLockReport;
import anyparse.check.ThreadSafety;
import anyparse.query.format.LintFormat.ExplainedLocks;

using Lambda;

/** The `lint --explain-long` halves around the checks: asking `thread-safety` to keep its long-lock evidence, and reading it back. */
@:nullSafety(Strict)
final class LintExplainLong {

	/**
	 * The run's `thread-safety` check, set to explain its long locks (`ThreadSafety.explainLongLocks`), when `on`; null
	 * when not, or — said on stderr — when the run does not include it.
	 */
	public static function explainer(checks: Array<Check>, on: Bool): Null<ThreadSafety> {
		if (!on) return null;
		final found: Null<Check> = checks.find(c -> c is ThreadSafety);
		if (found == null) {
			CliIo.stderr('apq lint: --explain-long: thread-safety is not among the rules this run reports — nothing to explain\n');
			return null;
		}
		final check: ThreadSafety = cast found;
		check.explainLongLocks(true);
		return check;
	}

	/**
	 * What the report carries for `--explain-long`: null when the flag is off; otherwise the check's report, or null — said
	 * on stderr — when the check ran and explained nothing (no file configures `sinks`, or `exclude` dropped every one) or
	 * was not run at all.
	 */
	public static function outcome(on: Bool, explainer: Null<ThreadSafety>): Null<ExplainedLocks> {
		if (!on) return null;
		final report: Null<LongLockReport> = explainer?.longLocks;
		if (explainer != null && report == null)
			CliIo.stderr(
				'apq lint: --explain-long: thread-safety explained nothing — no file was left to analyse: none configures `sinks`, or `exclude` dropped every one\n'
			);
		return { report: report };
	}

}
