package anyparse.query.cli;

import anyparse.query.ExitCode.*;

/**
 * What one `apq` invocation knows about itself, handed to every command the
 * registry runs.
 *
 * It exists for a specific reason rather than as a general bag: `--exit-on-empty`
 * / `--require-match` is parsed once, by the dispatcher, and consumed much later
 * by whichever find-walker the run ended in. `Cli` carried it across that gap in
 * a `private static var` — the ONE piece of process-scoped mutable state in the
 * CLI, and the shape invariant 1 rules out, since a second run in the same
 * process observes whatever the first one left. A field on a per-run instance is
 * the same value with none of that.
 *
 * Immutable by construction: a command reads the run, it does not reconfigure it.
 */
@:nullSafety(Strict)
final class CliContext {

	/**
	 * True when the invocation carried `--exit-on-empty` (or its alias
	 * `--require-match`), which turns a 0-hit walk into a non-zero exit so a
	 * script can tell "found nothing" from "ran fine".
	 */
	public final requireMatch: Bool;

	public function new(requireMatch: Bool) {
		this.requireMatch = requireMatch;
	}

	/**
	 * The exit status a find-walker answers with, given whether it found
	 * nothing. Without `--exit-on-empty` an empty walk is still a successful
	 * run, which is why a bare `apq refs X …; echo $$?` cannot distinguish
	 * found-vs-gone.
	 */
	public inline function emptyExit(empty: Bool): Int {
		return empty && requireMatch ? EXIT_RUNTIME : EXIT_OK;
	}

}
