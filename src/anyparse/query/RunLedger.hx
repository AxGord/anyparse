package anyparse.query;

import anyparse.ds.Set;

/**
 * The one answer to "has this run already said this diagnostic": the warn-once ledgers of a run, one per topic, replaced as a
 * whole when the next run begins (`Cli.run`), so a call in a long-lived engine process starts clean by construction rather than
 * by a reset each ledger's owner must remember.
 *
 * A direct caller outside any `Cli.run` shares the ledger of the most recent run, or the initial one before the first run;
 * docs/design-principles.md § 2.
 */
@:nullSafety(Strict)
final class RunLedger {

	private static var current: RunLedger = new RunLedger();

	private final _said: Set<String> = new Set();

	private function new() {}

	/** Starts a run with nothing said. */
	public static function begin(): Void {
		current = new RunLedger();
	}

	/** True the first time `key` is asked under `topic` in this run, false on every later ask. */
	public static function first(topic: String, key: String): Bool {
		final entry: String = entryOf(topic, key);
		if (current._said.has(entry)) return false;
		current._said.add(entry);
		return true;
	}

	/** Whether `key` was already said under `topic` in this run, without saying it. */
	public static function said(topic: String, key: String): Bool {
		return current._said.has(entryOf(topic, key));
	}

	/** Every key said under `topic` in this run. */
	public static function keysOf(topic: String): Array<String> {
		final prefix: String = entryOf(topic, '');
		return [
			for (entry in current._said) if (entry.startsWith(prefix)) entry.substr(prefix.length)
		];
	}

	/** A topic never holds a line break, so the first one separates topic from key unambiguously. */
	private static inline function entryOf(topic: String, key: String): String {
		return '$topic\n$key';
	}

}
