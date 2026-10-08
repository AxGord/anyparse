package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.ThreadSafety;

using Lambda;

/** The `lint --explain-long` half that runs BEFORE the checks: asking `thread-safety` to keep its long-lock evidence. */
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

}
