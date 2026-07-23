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

	/** The declared library source roots (`resolutionRoots`), each resolved to absolute against the config directory; an empty array when the key is absent. */
	private final _resolutionRoots: Array<String>;

	/** The declared haxelib library names (`resolutionLibs`) — verbatim strings; the CLI resolves each to a source dir lazily via `haxelib libpath`. An empty array when the key is absent. */
	private final _resolutionLibs: Array<String>;

	public function new(
		rules: Map<String, RuleConfig>, ?compilerOracle: String, ?compilerOracleDir: String, ?resolutionRoots: Array<String>,
		?resolutionLibs: Array<String>
	) {
		_rules = rules;
		_compilerOracle = compilerOracle;
		_compilerOracleDir = compilerOracleDir;
		_resolutionRoots = resolutionRoots ?? [];
		_resolutionLibs = resolutionLibs ?? [];
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

	/**
	 * The declared library source roots (`resolutionRoots`) — extra directories whose
	 * `.hx` sources join the resolution scope so the cross-file type / inheritance
	 * checks resolve against libraries, without those files ever being reported or
	 * edited. Each is resolved to absolute against the config directory; an empty
	 * array when the key is absent.
	 */
	public function resolutionRoots(): Array<String> {
		return _resolutionRoots;
	}

	/**
	 * The declared haxelib library names (`resolutionLibs`) — the preferred form for
	 * an installed library: the CLI resolves each name to the library's source dir via
	 * `haxelib libpath` (honouring a `haxelib dev` link and the current version) and
	 * joins them into the resolution scope, LAZILY, only when a check demands the index.
	 * Verbatim names here (no shell-out at parse time); an empty array when the key is absent.
	 */
	public function resolutionLibs(): Array<String> {
		return _resolutionLibs;
	}

	/**
	 * Whether `id` runs in the default set. `defaultOn` is the rule's default when its
	 * `enabled` key is absent — true for an ordinary rule, false for a `DefaultOff` rule
	 * the caller opts into. A present `enabled` value always wins.
	 */
	public function enabledFor(id: String, defaultOn: Bool = true): Bool {
		final rc: Null<RuleConfig> = _rules[id];
		return rc == null ? defaultOn : (rc.enabled ?? defaultOn);
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

	/** A rule-specific boolean option (e.g. `doc-coverage` `requireTypeDoc`), or null when unset or non-boolean. */
	public function boolOption(id: String, key: String): Null<Bool> {
		final v: Null<Dynamic> = propOf(id, key);
		return v == null || !(v is Bool) ? null : (v: Bool);
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
		final roots: Array<String> = [];
		final libs: Array<String> = [];
		final root: Null<Dynamic> = try haxe.Json.parse(content) catch (exception: Exception) null;
		if (root != null && Reflect.isObject(root)) {
			final rulesField: Null<Dynamic> = Reflect.field(root, 'rules');
			if (rulesField != null && Reflect.isObject(rulesField)) {
				final access: DynamicAccess<Dynamic> = rulesField;
				for (id => raw in access) if (raw != null && Reflect.isObject(raw)) rules[id] = parseRule(raw);
			}
			final oracleField: Null<Dynamic> = Reflect.field(root, 'compilerOracle');
			if (oracleField != null && oracleField is String) oracle = (oracleField: String);
			final rootsField: Null<Dynamic> = Reflect.field(root, 'resolutionRoots');
			if (rootsField != null && rootsField is Array) for (entry in (rootsField: Array<Dynamic>)) if (entry is String)
				roots.push(resolveRoot(baseDir, (entry: String)));
			final libsField: Null<Dynamic> = Reflect.field(root, 'resolutionLibs');
			if (libsField != null && libsField is Array) for (entry in (libsField: Array<Dynamic>)) if (entry is String)
				libs.push((entry: String));
		}
		return new LintConfig(rules, oracle, oracle == null ? null : baseDir, roots, libs);
	}

	private static function parseRule(raw: Dynamic): RuleConfig {
		final props: DynamicAccess<Dynamic> = raw;
		final enabledRaw: Null<Dynamic> = props.get('enabled');
		final severityRaw: Null<Dynamic> = props.get('severity');
		final enabled: Null<Bool> = enabledRaw is Bool ? enabledRaw : null;
		final severity: Null<Severity> = severityRaw != null && severityRaw is String ? Severity.fromName(severityRaw) : null;
		return { enabled: enabled, severity: severity, props: props };
	}

	/** Resolve a `resolutionRoots` entry to absolute against the config directory; a verbatim absolute path (or one parsed without a base) is kept as-is. */
	private static function resolveRoot(baseDir: Null<String>, root: String): String {
		return baseDir == null || haxe.io.Path.isAbsolute(root) ? root : haxe.io.Path.normalize(haxe.io.Path.join([baseDir, root]));
	}

}
