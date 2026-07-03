package anyparse.check;

import anyparse.query.ConfigFinder;
import haxe.DynamicAccess;
import haxe.Exception;

/**
 * Config for a single rule: an optional `enabled` toggle, an optional
 * `severity` override, and `props` carrying every other key verbatim for
 * rule-specific options (e.g. complexity `max`). Severity is parsed eagerly
 * via `Severity.fromName`; unknown labels become null (no override).
 */
typedef RuleConfig = {
	var ?enabled: Bool;
	var ?severity: Severity;
	var props: DynamicAccess<Dynamic>;
}

/**
 * Project-level lint configuration, read from an `apqlint.json` discovered by
 * walking up from a linted file's directory (the apq-native counterpart of the
 * `checkstyle.json` compat config). Grammar-agnostic — it keys rules by their
 * `Check.id()`, so any grammar's checks are configurable. Three knobs per rule:
 *
 *  - `enabled` — drop a rule from the default check set.
 *  - `severity` — override the severity a rule reports at.
 *  - rule-specific options (e.g. `max`) — read by the owning check.
 *
 * `enabled`/`severity` are applied by the framework (`Cli.runLint` /
 * `Linter.run`); options are pulled by the check itself (`Complexity`). A
 * missing or malformed file yields an empty config, so absence is a no-op.
 */
@:nullSafety(Strict)
final class LintConfig {

	private final _rules: Map<String, RuleConfig>;

	public function new(rules: Map<String, RuleConfig>) {
		_rules = rules;
	}

	/** Whether `id` runs in the default set (absent, or no `enabled` key → true). */
	public function enabledFor(id: String): Bool {
		final rc: Null<RuleConfig> = _rules[id];
		return rc == null || (rc.enabled ?? true);
	}

	/** The configured severity override for `id`, or null when unset. */
	public function severityFor(id: String): Null<Severity> {
		final rc: Null<RuleConfig> = _rules[id];
		return rc == null ? null : rc.severity;
	}

	/** A rule-specific integer option (e.g. complexity `max`), or null when unset. */
	public function intOption(id: String, key: String): Null<Int> {
		final rc: Null<RuleConfig> = _rules[id];
		if (rc == null) return null;
		final v: Null<Dynamic> = rc.props.get(key);
		return v == null || !(v is Int || v is Float) ? null : Std.int(v);
	}

	/**
	 * A rule-specific list-of-numbers option (e.g. `magic-number` `ignore`),
	 * or null when unset; a non-array value or non-numeric elements are dropped.
	 */
	public function numberListOption(id: String, key: String): Null<Array<Float>> {
		final rc: Null<RuleConfig> = _rules[id];
		if (rc == null) return null;
		final v: Null<Dynamic> = rc.props.get(key);
		if (v == null || !(v is Array)) return null;
		final raw: Array<Dynamic> = v;
		return [for (e in raw) if (e is Int || e is Float) (e: Float)];
	}

	/**
	 * Discover an `apqlint.json` by walking up from `path`'s directory and parse
	 * it; an empty config (every rule enabled, no overrides) when none is found.
	 */
	public static function discover(path: String): LintConfig {
		final content: Null<String> = ConfigFinder.findUp(path, 'apqlint.json');
		return parse(content ?? '{}');
	}

	/**
	 * Parse `apqlint.json` content. Tolerant: malformed JSON, a non-object root,
	 * or a missing `rules` object all yield an empty config — never throws, so a
	 * broken config degrades to default behaviour rather than failing the lint.
	 */
	public static function parse(content: String): LintConfig {
		final rules: Map<String, RuleConfig> = [];
		final root: Null<Dynamic> = try haxe.Json.parse(content) catch (exception: Exception) null;
		if (root != null && Reflect.isObject(root)) {
			final rulesField: Null<Dynamic> = Reflect.field(root, 'rules');
			if (rulesField != null && Reflect.isObject(rulesField)) {
				final access: DynamicAccess<Dynamic> = rulesField;
				for (id => raw in access) if (raw != null && Reflect.isObject(raw)) rules[id] = parseRule(raw);
			}
		}
		return new LintConfig(rules);
	}

	private static function parseRule(raw: Dynamic): RuleConfig {
		final props: DynamicAccess<Dynamic> = raw;
		final enabledRaw: Null<Dynamic> = props.get('enabled');
		final severityRaw: Null<Dynamic> = props.get('severity');
		final enabled: Null<Bool> = enabledRaw is Bool ? enabledRaw : null;
		final severity: Null<Severity> = severityRaw != null && severityRaw is String ? Severity.fromName(severityRaw) : null;
		return { enabled: enabled, severity: severity, props: props };
	}

	/**
	 * A rule-specific list-of-strings option (e.g. `thread-safety` `sinks`),
	 * or null when unset; a non-array value or non-string elements are dropped.
	 */
	public function stringListOption(id: String, key: String): Null<Array<String>> {
		final rc: Null<RuleConfig> = _rules[id];
		if (rc == null) return null;
		final v: Null<Dynamic> = rc.props.get(key);
		if (v == null || !(v is Array)) return null;
		final raw: Array<Dynamic> = v;
		return [for (e in raw) if (e is String) (e: String)];
	}

}
