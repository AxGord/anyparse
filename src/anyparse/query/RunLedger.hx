package anyparse.query;

import anyparse.ds.Set;

/**
 * The one answer to "has this run already said this diagnostic": the warn-once ledgers of a run, one per topic. A run owns one,
 * made by `Cli.run` (or handed to it), so a call in a long-lived engine process starts clean by construction rather than by a reset
 * each ledger's owner must remember; docs/design-principles.md § 2.
 *
 * A command reads its run's ledger off its `CliContext` and a rule gets it handed by its caller; nothing is shared between runs.
 */
@:nullSafety(Strict)
final class RunLedger {

	private final _said: Set<String> = new Set();

	public function new() {}

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

	/** A topic never holds a line break, so the first one separates topic from key unambiguously. */
	private static inline function entryOf(topic: String, key: String): String {
		return '$topic\n$key';
	}

}
