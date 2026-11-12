package anyparse.check;

import anyparse.check.LintConfig.ConfigNote;
import anyparse.query.RunLedger;

/**
 * The one answer to "where does a config diagnostic go": every reader collects it into the caller's notes,
 * and the caller says them — a command through its run ledger, a caller with no ledger of its own through
 * `warn`, once per run on stderr.
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

	/** Prints each collected note on stderr once per run, for a caller that holds no ledger; empties `notes`. */
	@:access(anyparse.check.LintConfig)
	public static function warn(notes: Array<ConfigNote>): Void {
		for (note in notes) LintConfig.warnOnce(note.key, note.message);
		notes.resize(0);
	}

	/**
	 * Prints each collected note through the run's `ledger`: a key said earlier this run — by a command or by the
	 * stderr fallback — is not said again.
	 */
	public static function say(ledger: RunLedger, notes: Array<ConfigNote>, write: (String) -> Void): Void {
		for (note in notes) if (ledger.first(note.topic ?? LintConfig.WARNED_TOPIC, note.key)) write(note.message);
		notes.resize(0);
	}

}
