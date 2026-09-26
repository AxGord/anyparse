package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.VersionGated;
import anyparse.check.LintConfig.DiscoveredConfig;
import haxe.io.Path;

using StringTools;
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
	 * One group per distinct (config chain, rule states) pair among `files`, in the order first met;
	 * the files keep their given order within a group. A directory's chain is resolved once, and the
	 * states are asked per file because a `FileGated` rule can answer differently for two files under
	 * one chain.
	 */
	public static function resolve(files: Array<String>, checks: Array<Check>): Array<RuleStateGroup> {
		final groups: Array<RuleStateGroup> = [];
		final byDir: Map<String, DiscoveredConfig> = [];
		for (file in files) {
			final dir: String = Path.directory(file);
			final found: DiscoveredConfig = byDir[dir] ?? LintConfig.discoverChain(file);
			byDir[dir] = found;
			groupFor(found.chain, [for (c in checks) stateOf(c, file, found.config)], groups).files.push(file);
		}
		return groups;
	}

	/** The state of `check` for `file` under `config`. */
	public static function stateOf(check: Check, file: String, config: LintConfig): RuleState {
		final id: String = check.id();
		final stated: Null<Bool> = config.enabledSetting(id);
		final enabled: Bool = stated ?? !(check is DefaultOff);
		final minimum: Null<String> = check is VersionGated ? (cast check: VersionGated).minLanguageVersion() : null;
		final gated: Bool = enabled && minimum != null && !config.allowsLanguageVersion(minimum);
		final skipped: Null<String> = enabled && !gated && check is FileGated ? (cast check: FileGated).skipReason(file, config) : null;
		final reason: String = if (gated)
			'needs-language-$minimum'
		else if (skipped != null)
			skipped
		else if (stated != null)
			'config'
		else if (enabled)
			'default'
		else
			'default-off';
		return {
			id: id,
			on: enabled && !gated && skipped == null,
			reason: reason,
			description: check.description()
		};
	}

	/**
	 * The listing `apq lint --list-rules <scope>` prints: per group, a header naming the chain nearest
	 * first, its `file:` lines, then `<id>  on|off  <reason>  <description>` per rule. Review tooling
	 * detects an hxq that supports the scoped form by the header, so its opening is a contract.
	 */
	public static function render(groups: Array<RuleStateGroup>): String {
		final out: StringBuf = new StringBuf();
		for (group in groups) {
			final chain: String = group.chain.length == 0 ? '(none — builtin defaults)' : group.chain.join(' <- ');
			out.add('=== effective lint rules — config chain: $chain ===\n');
			for (file in group.files) out.add('file: $file\n');
			final idWidth: Int = group.rules.fold((r, w) -> r.id.length > w ? r.id.length : w, 0);
			final reasonWidth: Int = group.rules.fold((r, w) -> r.reason.length > w ? r.reason.length : w, 0);
			for (r in group.rules) {
				final state: String = r.on ? 'on ' : 'off';
				out.add('${r.id.rpad(' ', idWidth)}  $state  ${r.reason.rpad(' ', reasonWidth)}  ${r.description}\n');
			}
		}
		return out.toString();
	}

	/** The existing group with this chain and these states, else a new one appended to `groups`. */
	private static function groupFor(chain: Array<String>, rules: Array<RuleState>, groups: Array<RuleStateGroup>): RuleStateGroup {
		final key: String = signature(chain, rules);
		final existing: Null<RuleStateGroup> = groups.find(g -> signature(g.chain, g.rules) == key);
		if (existing != null) return existing;
		final created: RuleStateGroup = { chain: chain, files: [], rules: rules };
		groups.push(created);
		return created;
	}

	/** One string per (chain, states) pair — what two files must share to be listed in one group. */
	private static function signature(chain: Array<String>, rules: Array<RuleState>): String {
		return chain.join('\n') + '\n\n' + [for (r in rules) '${r.id} ${r.on} ${r.reason}'].join('\n');
	}

}
