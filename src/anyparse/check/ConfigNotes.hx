package anyparse.check;

import anyparse.check.LintConfig.ConfigNote;
import anyparse.query.RunLedger;

/**
 * The one answer to "where does a config diagnostic go": to the caller's notes when it collects them — a
 * command then prints them through the run ledger — and otherwise once per run on stderr, the fallback for a
 * caller with no ledger of its own.
 */
@:nullSafety(Strict)
final class ConfigNotes {

	@:access(anyparse.check.LintConfig)
	public static function note(notes: Null<Array<ConfigNote>>, key: String, message: String): Void {
		if (notes != null)
			notes.push({ key: key, message: message });
		else
			LintConfig.warnOnce(key, message);
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
