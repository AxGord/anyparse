package anyparse.check;

import anyparse.check.LintConfig.ConfigNote;
import anyparse.ds.Set;
import anyparse.query.RunLedger;

/**
 * The one answer to "where does a config diagnostic go": every reader collects it into the caller's notes,
 * and the caller says them — a command through its run ledger, a caller with no ledger of its own through
 * `warn` on stderr, each key once over the calls that share one `said` set. No ledger is reached for beyond
 * the one a caller passes: what a run has said is the run's (docs/design-principles.md § 2).
 */
@:nullSafety(Strict)
final class ConfigNotes {

	public static function note(notes: Array<ConfigNote>, key: String, message: String): Void {
		notes.push({ key: key, message: message });
	}

	/**
	 * Answers `read` over `notes` when the caller collects them; with none, over a fresh array whose notes `warn`
	 * says right after — the one fallback for a reader whose caller holds no ledger.
	 */
	public static function into<T>(notes: Null<Array<ConfigNote>>, read: (Array<ConfigNote>) -> T): T {
		if (notes != null) return read(notes);
		final own: Array<ConfigNote> = [];
		final answer: T = read(own);
		warn(own);
		return answer;
	}

	/**
	 * Prints on stderr, through `write` when given, each collected note whose key `said` does not hold yet, and empties
	 * `notes`: the path of a caller that holds no ledger. A caller that warns more than once keeps one `said` across its
	 * calls, so a key is said once over all of them; with none, once within this array.
	 */
	public static function warn(notes: Array<ConfigNote>, ?said: Set<String>, ?write: (String) -> Void): Void {
		final seen: Set<String> = said ?? new Set();
		for (note in notes) if (!seen.has(note.key)) {
			seen.add(note.key);
			(write ?? stderr)(note.message);
		}
		notes.resize(0);
	}

	/** Prints each collected note through the run's `ledger`: a key said earlier this run is not said again. */
	public static function say(ledger: RunLedger, notes: Array<ConfigNote>, write: (String) -> Void): Void {
		for (note in notes) if (ledger.first(note.topic ?? LintConfig.WARNED_TOPIC, note.key)) write(note.message);
		notes.resize(0);
	}

	/** Guarded stderr write — mirrors `Cli.stderr` (`#if sys` alone is false on hxnodejs). */
	private static function stderr(s: String): Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
	}

}
