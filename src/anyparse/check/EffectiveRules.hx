package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.VersionGated;
import anyparse.check.LintConfig.DiscoveredConfig;
import haxe.io.Path;

using Lambda;

/** Whether one rule runs for a group of files, and what decided it. */
typedef RuleState = {
	var id: String;
	var on: Bool;

	/**
	 * `default` / `default-off` when the config says nothing about the rule, `config` when it
	 * sets `enabled`, `needs-language-<v>` when the declared `languageVersion` is below what the
	 * rule's fix emits — the gate `Linter.run` drops such a rule's findings by.
	 */
	var reason: String;
	var description: String;
}

/** The files that resolve through one `apqlint.json` chain, and the state of every rule for them. */
typedef RuleStateGroup = {
	var chain: Array<String>;
	var files: Array<String>;
	var rules: Array<RuleState>;
}

/**
 * The rule set a lint of some files ACTUALLY runs, per file: the registry after the config chain,
 * `DefaultOff` and the `languageVersion` gate are applied.
 *
 * The registry alone overstates it — a config disables rules and a default-off rule runs only where
 * a config enables it — so a reviewer who subtracts the registry from a manual checklist drops
 * checks nobody ran. The answer is the same `enabledFor` / `allowsLanguageVersion` pair
 * `Linter.run` applies to findings, asked of the same per-directory `LintConfig.discover`.
 */
@:nullSafety(Strict)
final class EffectiveRules {

	/**
	 * One group per distinct config chain among `files`, in the order the chains are first met; the
	 * files keep their given order within a group. A directory is resolved once.
	 */
	public static function resolve(files: Array<String>, checks: Array<Check>): Array<RuleStateGroup> {
		final groups: Array<RuleStateGroup> = [];
		final byDir: Map<String, RuleStateGroup> = [];
		for (file in files) {
			final dir: String = Path.directory(file);
			final group: RuleStateGroup = byDir[dir] ?? groupFor(LintConfig.discoverChain(file), checks, groups);
			byDir[dir] = group;
			group.files.push(file);
		}
		return groups;
	}

	/** The state of `check` under `config`. */
	public static function stateOf(check: Check, config: LintConfig): RuleState {
		final id: String = check.id();
		final stated: Null<Bool> = config.enabledSetting(id);
		final enabled: Bool = stated ?? !(check is DefaultOff);
		final minimum: Null<String> = check is VersionGated ? (cast check: VersionGated).minLanguageVersion() : null;
		final gated: Bool = enabled && minimum != null && !config.allowsLanguageVersion(minimum);
		final reason: String = if (gated)
			'needs-language-$minimum'
		else if (stated != null)
			'config'
		else if (enabled)
			'default'
		else
			'default-off';
		return {
			id: id,
			on: enabled && !gated,
			reason: reason,
			description: check.description()
		};
	}

	/** The existing group whose chain equals `found`'s, else a new one appended to `groups`. */
	private static function groupFor(found: DiscoveredConfig, checks: Array<Check>, groups: Array<RuleStateGroup>): RuleStateGroup {
		final key: String = found.chain.join('\n');
		final existing: Null<RuleStateGroup> = groups.find(g -> g.chain.join('\n') == key);
		if (existing != null) return existing;
		final created: RuleStateGroup = {
			chain: found.chain,
			files: [],
			rules: [for (c in checks) stateOf(c, found.config)]
		};
		groups.push(created);
		return created;
	}

}
