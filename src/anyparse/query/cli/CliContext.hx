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
 * Immutable by construction: a command reads the run, it does not reconfigure it. The one thing a run writes is
 * what its find-walk found (`matches`), into a cell the runs of one call share.
 */
@:nullSafety(Strict)
final class CliContext {

	/**
	 * True when the invocation carried `--exit-on-empty` (or its alias
	 * `--require-match`), which turns a 0-hit walk into a non-zero exit so a
	 * script can tell "found nothing" from "ran fine".
	 */
	public final requireMatch: Bool;

	/**
	 * True when the invocation carried `--fix` on a command that declares
	 * `PostWriteFix` — the opt-in that makes a write op lint what it just wrote and
	 * apply the safe fixes, scoped to the lines the write actually changed.
	 *
	 * Parsed by the dispatcher like `requireMatch` above and for the same reason: the
	 * flag is written next to the op, and read much later, in the shared edit tail.
	 * Defaulted so that a `CliContext` built for a run that never saw the flag — every
	 * command outside that set, and the tests that construct one directly — is the
	 * value it always was.
	 */
	public final postWriteFix: Bool;

	/**
	 * Standard input, when the dispatcher already read it to tell a document's grammar by its content — a pipe
	 * reads once, so a command that takes its document from stdin reads it through `readStdin`, never `CliIo`.
	 */
	public final stdin: Null<String>;

	/** What the find-walks of this call found, shared by the contexts of its runs (`Cli`'s `runEach` reads it). */
	public final matches: RunMatches;

	public function new(requireMatch: Bool, postWriteFix: Bool = false, ?stdin: String, ?matches: RunMatches) {
		this.requireMatch = requireMatch;
		this.postWriteFix = postWriteFix;
		this.stdin = stdin;
		this.matches = matches ?? new RunMatches();
	}

	/**
	 * The exit status a find-walker answers with, given whether it found
	 * nothing. Without `--exit-on-empty` an empty walk is still a successful
	 * run, which is why a bare `apq refs X …; echo $$?` cannot distinguish
	 * found-vs-gone.
	 */
	public inline function emptyExit(empty: Bool): Int {
		matches.record(empty);
		return empty && requireMatch ? EXIT_RUNTIME : EXIT_OK;
	}

	/** Standard input: what the dispatcher already read, else read now. */
	public function readStdin(): String {
		return stdin ?? CliIo.readStdin();
	}

}
