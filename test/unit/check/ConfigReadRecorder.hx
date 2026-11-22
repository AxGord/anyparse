package unit.check;

import anyparse.check.LintConfig;

/**
 * The one answer to "which `apq.json` keys does this check read": a `LintConfig` that holds no options and remembers which
 * option keys each rule's check asked for, so the answer comes from running the check and not from reading its source.
 *
 * Every typed reader (`int`, `bool`, `stringList`, `jsonOption`, `optionKeys`) reports through the config's option observer.
 * A rule asked for its key SET (`optionKeys`) is recorded as read with no key.
 */
@:nullSafety(Strict)
final class ConfigReadRecorder {

	/** Rule id -> the keys its check asked for, in the order asked; a rule never asked for an option is absent. */
	public final reads: Map<String, Array<String>> = [];

	private final _enabled: Array<String>;

	/** `enabled` names the rules the config switches on, so a rule that is off unless asked still runs. */
	public function new(enabled: Array<String>) {
		_enabled = enabled;
	}

	/** The config to hand a run as its per-file resolver's answer. */
	public function config(): LintConfig {
		final switches: Array<RuleSwitches> = [{ rules: [ for (id in _enabled) id => true ], categories: [] }];
		return new LintConfig([], null, null, null, true, false, null, null, null, false, 100, null, null, null, switches, null, record);
	}

	private function record(id: String, key: Null<String>): Void {
		final keys: Array<String> = reads[id] ?? [];
		reads[id] = keys;
		if (key != null && !keys.contains(key)) keys.push(key);
	}

}
