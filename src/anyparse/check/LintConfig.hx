package anyparse.check;

import anyparse.check.config.ApqLintConfig;
import anyparse.check.config.ApqLintConfigParser;
import anyparse.grammar.json.JValue;
import anyparse.query.ConfigFinder;
import haxe.Exception;

/**
 * Config for a single rule: an optional `enabled` toggle, an optional
 * `severity` override, and `props` carrying every other key verbatim for
 * rule-specific options (e.g. complexity `max`). Severity is parsed eagerly
 * via `Severity.fromName`; unknown labels become null (no override). A prop value
 * stays a raw `JValue` — the bag is rule-specific, so the typed accessors on
 * `LintConfig` narrow each one per read.
 */
typedef RuleConfig = {
	var ?enabled: Bool;
	var ?severity: Severity;
	var props: Map<String, JValue>;
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
 *
 * The JSON is read through the declared `ApqLintConfig` schema and its
 * macro-generated `ApqLintConfigParser` — the same typed route `hxformat.json`
 * and `checkstyle.json` take.
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

	/** Whether the auto-discovered Haxe std may join the resolution scope (`resolutionStd`); true unless the key explicitly declines it. */
	private final _resolutionStd: Bool;

	public function new(
		rules: Map<String, RuleConfig>, ?compilerOracle: String, ?compilerOracleDir: String, ?resolutionRoots: Array<String>,
		?resolutionLibs: Array<String>, ?resolutionStd: Bool
	) {
		_rules = rules;
		_compilerOracle = compilerOracle;
		_compilerOracleDir = compilerOracleDir;
		_resolutionRoots = resolutionRoots ?? [];
		_resolutionLibs = resolutionLibs ?? [];
		_resolutionStd = resolutionStd ?? true;
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
	 * Whether the auto-discovered Haxe std joins the resolution scope — true unless the config
	 * declares `"resolutionStd": false`. The opt-OUT for a project whose sources target a
	 * different Haxe version than the one installed on the machine: without it, `StdResolver`
	 * falls through to its known install locations, so clearing `HAXE_STD_PATH` and stripping
	 * `haxe` from `PATH` still yields a std and the project silently resolves against it. Only
	 * the std channel is declined; declared `resolutionRoots` / `resolutionLibs` are unaffected.
	 * The process-wide twin is the `APQ_NO_STD` env var (`StdResolver`), which also cuts the
	 * std-derived tables.
	 */
	public function resolutionStd(): Bool {
		return _resolutionStd;
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

	/** A rule-specific integer option (e.g. complexity `max`), or null when unset or non-numeric. A fractional value truncates, as it always has. */
	public function intOption(id: String, key: String): Null<Int> {
		return switch propOf(id, key) {
			case JNumber(v): Std.int(v);
			case null, _: null;
		};
	}

	/** A rule-specific boolean option (e.g. `doc-coverage` `requireTypeDoc`), or null when unset or non-boolean. */
	public function boolOption(id: String, key: String): Null<Bool> {
		return switch propOf(id, key) {
			case JBool(v): v;
			case null, _: null;
		};
	}

	/**
	 * A rule-specific list-of-numbers option (e.g. `magic-number` `ignore`),
	 * or null when unset; a non-array value or non-numeric elements are dropped.
	 */
	public function numberListOption(id: String, key: String): Null<Array<Float>> {
		final raw: Null<Array<JValue>> = arrayOption(id, key);
		if (raw == null) return null;
		final out: Array<Float> = [];
		for (item in raw) switch item {
			case JNumber(v):
				out.push(v);
			case _:
		}
		return out;
	}

	/**
	 * A rule-specific list-of-strings option (e.g. `thread-safety` `sinks`),
	 * or null when unset; a non-array value or non-string elements are dropped.
	 */
	public function stringListOption(id: String, key: String): Null<Array<String>> {
		final raw: Null<Array<JValue>> = arrayOption(id, key);
		if (raw == null) return null;
		final out: Array<String> = [];
		for (item in raw) switch item {
			case JString(v):
				out.push(v);
			case _:
		}
		return out;
	}

	/** The raw prop `key` of rule `id`, or null when the rule is unconfigured or lacks the key — the base for the typed option accessors. */
	private function propOf(id: String, key: String): Null<JValue> {
		final rc: Null<RuleConfig> = _rules[id];
		return rc == null ? null : rc.props[key];
	}

	/** The raw array prop `key` of rule `id`, or null when it is unset or not an array — the array base for the list accessors. */
	private function arrayOption(id: String, key: String): Null<Array<JValue>> {
		return switch propOf(id, key) {
			case JArray(items): items;
			case null, _: null;
		};
	}

	/**
	 * Discover an `apqlint.json` by walking up from `path`'s directory and parse
	 * it; an empty config (every rule enabled, no overrides) when none is found.
	 */
	public static function discover(path: String): LintConfig {
		final found: Null<{ content: String, path: String }> = ConfigFinder.findUpFile(path, 'apqlint.json');
		if (found == null) return new LintConfig([]);
		final config: Null<LintConfig> = parseOrNull(found.content, haxe.io.Path.directory(found.path));
		if (config == null) {
			// A REAL config file that the schema rejects must not degrade
			// silently — the wholesale fallback quietly collapses the
			// resolution scope and every rule toggle. Once per file per
			// process: `discover` re-runs for every linted directory
			// (the CLI memoises per directory, not per config), so an
			// unde-duplicated line would repeat N times per run.
			if (!_warnedConfigs.contains(found.path)) {
				_warnedConfigs.push(found.path);
				stderr('apq: ${found.path} failed to parse — using defaults\n');
			}
			return new LintConfig([]);
		}
		return config;
	}

	/** Config paths already reported by `discover`'s reject diagnostic — one line per file per process. */
	private static final _warnedConfigs: Array<String> = [];

	/** Guarded stderr write — mirrors `Cli.stderr` (`#if sys` alone is false on hxnodejs). */
	private static function stderr(s: String): Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
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
	 * Parse `apqlint.json` content through the declared `ApqLintConfig` schema.
	 * Tolerant: malformed JSON, a non-object root, or a value contradicting the
	 * schema all yield an empty config — never throws, so a broken config
	 * degrades to default behaviour rather than failing the lint.
	 *
	 * A wrong-TYPED value now degrades the WHOLE config rather than just its own
	 * key (the schema rejects the document, and the catch below swallows it) —
	 * the same boundary `CheckstyleConfigLoader` moved to. Per-VALUE leniency
	 * survives inside `rules`, whose entries stay raw JSON on purpose.
	 */
	public static function parse(content: String, ?baseDir: String): LintConfig {
		return parseOrNull(content, baseDir) ?? new LintConfig([]);
	}

	/**
	 * `parse`'s worker: the typed parse and mapping, or null when the
	 * schema rejects the document. `parse` folds the null into the
	 * silent empty config (it cannot tell a probe from a real config
	 * file, so it never prints); `discover` turns the same null into
	 * the user-facing diagnostic, because it knows the file path.
	 */
	private static function parseOrNull(content: String, ?baseDir: String): Null<LintConfig> {
		final config: Null<ApqLintConfig> = try ApqLintConfigParser.parse(content) catch (exception: Exception) null;
		if (config == null) return null;
		final rules: Map<String, RuleConfig> = [];
		final declared: Null<Map<String, JValue>> = config.rules;
		if (declared != null) for (id => raw in declared) {
			final rule: Null<RuleConfig> = parseRule(raw);
			if (rule != null) rules[id] = rule;
		}
		final oracle: Null<String> = config.compilerOracle;
		final roots: Array<String> = (config.resolutionRoots ?? []).map(resolveRoot.bind(baseDir));
		return new LintConfig(rules, oracle, oracle == null ? null : baseDir, roots, config.resolutionLibs, config.resolutionStd);
	}

	/**
	 * One `rules` entry → its `RuleConfig`. `enabled` (a JSON boolean) and
	 * `severity` (a JSON string resolved through `Severity.fromName`, an
	 * unknown label yielding no override) are lifted out; every other key stays
	 * in `props` verbatim for the owning check to read. A value that is not a
	 * JSON object is not a rule config at all — null, and the caller drops the
	 * entry, exactly as the untyped reader skipped a non-object.
	 */
	private static function parseRule(raw: JValue): Null<RuleConfig> {
		return switch raw {
			case JObject(entries):
				var enabled: Null<Bool> = null;
				var severity: Null<Severity> = null;
				final props: Map<String, JValue> = [];
				for (entry in entries) {
					final key: String = entry.key;
					final value: JValue = entry.value;
					switch [key, value] {
						case ['enabled', JBool(v)]:
							enabled = v;
						case ['severity', JString(v)]:
							severity = Severity.fromName(v);
						case _:
							props[key] = value;
					}
				}
				{ enabled: enabled, severity: severity, props: props };
			case _: null;
		};
	}

	/** Resolve a `resolutionRoots` entry to absolute against the config directory; a verbatim absolute path (or one parsed without a base) is kept as-is. */
	private static function resolveRoot(baseDir: Null<String>, root: String): String {
		return baseDir == null || haxe.io.Path.isAbsolute(root) ? root : haxe.io.Path.normalize(haxe.io.Path.join([baseDir, root]));
	}

}
