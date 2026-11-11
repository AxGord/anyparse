package anyparse.query;

import anyparse.ds.Set;

/**
 * The one answer to "has this run already said this diagnostic": the warn-once ledgers of a run, one per topic, replaced as a
 * whole when the next run begins (`Cli.run`), so a call in a long-lived engine process starts clean by construction rather than
 * by a reset each ledger's owner must remember.
 *
 * A command reads its run's ledger off its `CliContext`. A caller with no context of its own — a rule, a write op's `--fix`
 * re-entry — shares the ledger of the most recent run (`fallback`), or the initial one before the first run;
 * docs/design-principles.md § 2.
 */
@:nullSafety(Strict)
final class RunLedger {

	private static var current: RunLedger = new RunLedger();

	private final _said: Set<String> = new Set();

	private function new() {}

	/** True the first time `key` is asked under `topic` in this run, false on every later ask. */
	public function first(topic: String, key: String): Bool {
		final entry: String = entryOf(topic, key);
		if (_said.has(entry)) return false;
		_said.add(entry);
		return true;
	}

	/** Whether `key` was already said under `topic` in this run, without saying it. */
	public function said(topic: String, key: String): Bool {
		return _said.has(entryOf(topic, key));
	}

	/** Every key said under `topic` in this run. */
	public function keysOf(topic: String): Array<String> {
		final prefix: String = entryOf(topic, '');
		return [for (entry in _said) if (entry.startsWith(prefix)) entry.substr(prefix.length)];
	}

	/** The ledger of the most recent run: what a caller holding no run's ledger of its own says through. */
	public static inline function fallback(): RunLedger {
		return current;
	}

	/** Starts a run with nothing said, and answers its ledger. */
	public static function begin(): RunLedger {
		current = new RunLedger();
		return current;
	}

	/** A topic never holds a line break, so the first one separates topic from key unambiguously. */
	private static inline function entryOf(topic: String, key: String): String {
		return '$topic\n$key';
	}

}
