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

	/** The `compilerOracle` hxml path verbatim from the config root, or null when unset. */
	private final _compilerOracle: Null<String>;

	/** The directory of the `apqlint.json` that declared the oracle — the compile CWD — or null when parsed without a base. */
	private final _compilerOracleDir: Null<String>;

	public function new(rules: Map<String, RuleConfig>, ?compilerOracle: String, ?compilerOracleDir: String) {
		_rules = rules;
		_compilerOracle = compilerOracle;
		_compilerOracleDir = compilerOracleDir;
	}

	/**
	 * The project's compiler-oracle hxml (the root `compilerOracle` key), or null
	 * when the config does not opt in. The path is verbatim from the JSON — the
	 * caller runs `haxe <path> --no-output` from `compilerOracleDir()` so a path
	 * relative to the `apqlint.json` resolves like `cd <project> && haxe <path>`.
	 */
	public function compilerOracle(): Null<String> {
		return _compilerOracle;
	}

	/** The working directory for the compiler-oracle run (the config file's directory), or null. */
	public function compilerOracleDir(): Null<String> {
		return _compilerOracleDir;
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
		final v: Null<Dynamic> = propOf(id, key);
		return v == null || !(v is Int || v is Float) ? null : Std.int(v);
	}

	/**
	 * A rule-specific list-of-numbers option (e.g. `magic-number` `ignore`),
	 * or null when unset; a non-array value or non-numeric elements are dropped.
	 */
	public function numberListOption(id: String, key: String): Null<Array<Float>> {
		final raw: Null<Array<Dynamic>> = arrayOption(id, key);
		return raw == null ? null : [for (e in raw) if (e is Int || e is Float) (e: Float)];
	}

	/**
	 * A rule-specific list-of-strings option (e.g. `thread-safety` `sinks`),
	 * or null when unset; a non-array value or non-string elements are dropped.
	 */
	public function stringListOption(id: String, key: String): Null<Array<String>> {
		final raw: Null<Array<Dynamic>> = arrayOption(id, key);
		return raw == null ? null : [for (e in raw) if (e is String) (e: String)];
	}

	/** The raw prop `key` of rule `id`, or null when the rule is unconfigured or lacks the key — the base for the typed option accessors. */
	private function propOf(id: String, key: String): Null<Dynamic> {
		final rc: Null<RuleConfig> = _rules[id];
		return rc == null ? null : rc.props.get(key);
	}

	/** The raw array prop `key` of rule `id`, or null when it is unset or not an array — the array base for the list accessors. */
	private function arrayOption(id: String, key: String): Null<Array<Dynamic>> {
		final v: Null<Dynamic> = propOf(id, key);
		return v == null || !(v is Array) ? null : (v: Array<Dynamic>);
	}

	/**
	 * Discover an `apqlint.json` by walking up from `path`'s directory and parse
	 * it; an empty config (every rule enabled, no overrides) when none is found.
	 */
	public static function discover(path: String): LintConfig {
		final found: Null<{ content: String, path: String }> = ConfigFinder.findUpFile(path, 'apqlint.json');
		return found == null ? parse('{}') : parse(found.content, haxe.io.Path.directory(found.path));
	}

	/**
	 * The config for `path` using `resolve` when the linter injected its memoised
	 * per-file resolver, else `discover(path)` — so an option-reading check threads
	 * the shared resolver in a CLI run but still resolves correctly when run directly.
	 */
	public static function resolveWith(resolve: Null<(String) -> LintConfig>, path: String): LintConfig {
		return resolve != null ? resolve(path) : discover(path);
	}


	/**
	 * Parse `apqlint.json` content. Tolerant: malformed JSON, a non-object root,
	 * or a missing `rules` object all yield an empty config — never throws, so a
	 * broken config degrades to default behaviour rather than failing the lint.
	 */
	public static function parse(content: String, ?baseDir: String): LintConfig {
		final rules: Map<String, RuleConfig> = [];
		var oracle: Null<String> = null;
		final root: Null<Dynamic> = try haxe.Json.parse(content) catch (exception: Exception) null;
		if (root != null && Reflect.isObject(root)) {
			final rulesField: Null<Dynamic> = Reflect.field(root, 'rules');
			if (rulesField != null && Reflect.isObject(rulesField)) {
				final access: DynamicAccess<Dynamic> = rulesField;
				for (id => raw in access) if (raw != null && Reflect.isObject(raw)) rules[id] = parseRule(raw);
			}
			final oracleField: Null<Dynamic> = Reflect.field(root, 'compilerOracle');
			if (oracleField != null && oracleField is String) oracle = (oracleField: String);
		}
		return new LintConfig(rules, oracle, oracle == null ? null : baseDir);
	}


	private static function parseRule(raw: Dynamic): RuleConfig {
		final props: DynamicAccess<Dynamic> = raw;
		final enabledRaw: Null<Dynamic> = props.get('enabled');
		final severityRaw: Null<Dynamic> = props.get('severity');
		final enabled: Null<Bool> = enabledRaw is Bool ? enabledRaw : null;
		final severity: Null<Severity> = severityRaw != null && severityRaw is String ? Severity.fromName(severityRaw) : null;
		return { enabled: enabled, severity: severity, props: props };
	}

}
