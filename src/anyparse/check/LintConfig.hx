package anyparse.check;

import anyparse.check.LintDocuments.DocumentMemo;
import anyparse.check.LintDocuments.LintDocument;
import anyparse.check.OwnedTypesDeclaration.TypeOwnership;
import anyparse.grammar.json.JValue;
import anyparse.query.ConfigFinder;
import anyparse.query.NamingPolicy.FrameworkContract;
import anyparse.query.format.LintFormat;
import haxe.io.Path;

using StringTools;

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
 * ONE compiler-oracle configuration: the hxml to typecheck, the directory that compile runs
 * from, and the extra defines it carries.
 *
 * The key declares a LIST of these because one hxml is one configuration while a `#if` has two
 * or more arms — an edit in code that only `#if android` compiles is typechecked by nothing a
 * macOS build runs, so a single configuration cannot keep the promise that a risky fix which
 * breaks the build is reverted.
 *
 * `defines` is EMPTY for the string form of the key, which is what makes that form the
 * one-element case of this list rather than a second code path.
 */
typedef OracleConfig = {
	var hxml: String;
	var dir: Null<String>;
	var defines: Array<String>;

	/** How to (re)create `hxml` before the configuration is used; absent for an hxml the project maintains itself. */
	var ?generate: OracleGenerate;

	/**
	 * Why this configuration cannot be asked at all — set by `OracleGeneration.prepare` when its `generate` command
	 * failed. Every consumer answers it as an oracle that could not run, never by reading a stale hxml.
	 */
	var ?unavailable: String;

	/**
	 * Why this run's generation of the hxml is no faithful snapshot of the tree — an input moved while the command ran —
	 * set by `OracleGeneration.prepare`. A report may still ask it; a `--fix` verification treats it as unavailable
	 * (`LintFixVerify.verifiable`), since a veto from a build that does not match the tree is worse than none.
	 */
	var ?raced: String;

	/**
	 * What the compiler already answered in the run this configuration belongs to — set by the lint command on the
	 * configurations it prepares for ONE run, absent everywhere else, and then every compile goes to the compiler.
	 */
	var ?runs: OracleRunMemo;
}

/**
 * A configuration's `generate` declaration, resolved: the shell `command` that writes its hxml, the directory it runs
 * in (`root` — the declaring config's directory), the absolute `inputs` whose content decides whether a recorded
 * generation is still current (null when the entry names none: then it regenerates once per run), and whether the
 * compile directory was left to be PROBED once the hxml exists (`probeDir`).
 */
typedef OracleGenerate = {
	var command: String;
	var root: String;
	var inputs: Null<Array<String>>;
	var probeDir: Bool;
}

/**
 * A discovered config together with the `apqlint.json` documents it was folded from, nearest
 * first; `chain` is empty when no document applies and the config is the builtin defaults.
 */
typedef DiscoveredConfig = {
	var config: LintConfig;
	var chain: Array<String>;
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

	/**
	 * Keys already diagnosed — a config path for `discover`'s own per-file lines, a
	 * `scope-disagreement:<setting>` or `scope-gap:<label>` key for a warning about the SCOPE rather than
	 * about one document. Each reports at most once per process, whatever it reported.
	 */
	private static final warnedConfigs: Array<String> = [];

	private final _rules: Map<String, RuleConfig>;

	/**
	 * The `compilerOracle` configurations, each hxml resolved against the declaring config's
	 * directory (verbatim when parsed without a base); an empty array when the key is absent.
	 */
	private final _compilerOracles: Array<OracleConfig>;

	/**
	 * Whether the project opted the oracle into the shared warm compilation
	 * server (`compilerOracleServer`); false unless the key asks for it.
	 */
	private final _compilerOracleServer: Bool;

	/** Whether the `compilerOracle` list covers every build the project ships (`reachConfigurationsComplete`); false unless declared. */
	private final _reachConfigurationsComplete: Bool;

	/** The globs naming every class made reflectively from a name the facts cannot read (`reflectiveClasses`); null unless declared. */
	private final _reflectiveClasses: Null<Array<String>>;

	/**
	 * The globs naming every class whose methods a read by a name the facts cannot read may obtain as values
	 * (`reflectiveMethodHolders`); null unless declared.
	 */
	private final _reflectiveMethodHolders: Null<Array<String>>;

	/**
	 * The declared source roots (`resolutionRoots`) — the project's own, see the accessor — each resolved
	 * to absolute against the config directory; an empty array when the key is absent.
	 */
	private final _resolutionRoots: Array<String>;

	/**
	 * The declared haxelib library names (`resolutionLibs`) — verbatim strings; the CLI resolves
	 * each to a source dir lazily via `haxelib libpath`. An empty array when the key is absent.
	 */
	private final _resolutionLibs: Array<String>;

	/** Whether the auto-discovered Haxe std may join the resolution scope (`resolutionStd`); true unless the key explicitly declines it. */
	private final _resolutionStd: Bool;

	/** The language version the project targets (`languageVersion`), or null when unset — see `Check.VersionGated`. */
	private final _languageVersion: Null<String>;

	/** The declared framework contracts (`frameworks`), already mapped off raw JSON; an empty array when the key is absent. */
	private final _frameworks: Array<FrameworkContract>;

	/** Ready diagnostic lines for the per-ENTRY drops this document survived — see `drops`. */
	private final _drops: Array<String>;

	/** How many findings a text report lists before it summarises them (`reportSummaryThreshold`); see the accessor. */
	private final _reportSummaryThreshold: Int;

	/** The declared type ownerships (`ownedTypes`), already mapped off raw JSON; an empty array when the key is absent. */
	private final _ownedTypes: Array<TypeOwnership>;

	public function new(
		rules: Map<String, RuleConfig>, ?compilerOracles: Array<OracleConfig>, ?resolutionRoots: Array<String>,
		?resolutionLibs: Array<String>, resolutionStd: Bool = true, compilerOracleServer: Bool = false, ?languageVersion: String,
		?frameworks: Array<FrameworkContract>, ?drops: Array<String>, reachConfigurationsComplete: Bool = false,
		reportSummaryThreshold: Int = LintFormat.DEFAULT_REPORT_SUMMARY_THRESHOLD, ?reflectiveClasses: Array<String>,
		?reflectiveMethodHolders: Array<String>, ?ownedTypes: Array<TypeOwnership>
	) {
		_ownedTypes = ownedTypes ?? [];
		_reportSummaryThreshold = reportSummaryThreshold;
		_reachConfigurationsComplete = reachConfigurationsComplete;
		_reflectiveClasses = reflectiveClasses;
		_reflectiveMethodHolders = reflectiveMethodHolders;
		_rules = rules;
		_compilerOracles = compilerOracles ?? [];
		_compilerOracleServer = compilerOracleServer;
		_resolutionRoots = resolutionRoots ?? [];
		_resolutionLibs = resolutionLibs ?? [];
		_resolutionStd = resolutionStd;
		_languageVersion = languageVersion;
		_frameworks = frameworks ?? [];
		_drops = drops ?? [];
	}

	/**
	 * A rule-specific option as the raw JSON the document wrote, or null when unset — for an option whose shape no typed
	 * accessor reads (`prefer-api-idiom`'s list of objects), so the owning check validates it entry by entry itself.
	 */
	public inline function jsonOption(id: String, key: String): Null<JValue> {
		return propOf(id, key);
	}

	/**
	 * Every compiler-oracle configuration the project declares (the root `compilerOracle`
	 * key), in declared order; an empty array when it does not opt in.
	 *
	 * There is ONE accessor because every caller is obliged to ask ALL of them: an edit is
	 * proved safe only by the configurations that actually typecheck it, and taking the first
	 * would re-open the cross-configuration hole the list exists to close. Each element's
	 * `dir` is the candidate under which that hxml's own relative `-cp` entries resolve
	 * (`hxmlCompileDir`) — its own directory for classpaths written relative to itself (a
	 * nested config naming `"../build.hxml"`), the CONFIG's directory for a lime/openfl-style
	 * `dist/<target>/haxe/debug.hxml` — or null when the config was parsed without a base
	 * directory, where there is nothing to resolve against.
	 */
	public function compilerOracles(): Array<OracleConfig> {
		return _compilerOracles;
	}

	/**
	 * Whether the compiler oracle may run through the project's shared warm compilation
	 * server (`compilerOracleServer`) instead of a fresh `haxe` process per lint run. Opt-in
	 * and false by default: the server is a daemon that OUTLIVES the run, which is a larger
	 * commitment than the typecheck `compilerOracle` asks for. Report mode honours it and
	 * falls back to the cold oracle whenever the server path cannot answer; the `--fix`
	 * risky-fix verification ignores it entirely, since a post-write typecheck is exactly
	 * what a compilation server cannot answer honestly (see `CompilerServer`).
	 */
	public function compilerOracleServer(): Bool {
		return _compilerOracleServer;
	}

	/**
	 * Whether the project declares its `compilerOracle` list COMPLETE for the reach analysis
	 * (`reachConfigurationsComplete`): every build it ships is one of those configurations. Only then may a
	 * conditional branch that none of them compiles be read as code that never runs, and a library file none of them
	 * parses as code that runs in no build — a platform build the list cannot typecheck (another OS, an app-store
	 * variant) still ships its branches. False by default: without it every branch is walked.
	 */
	public function reachConfigurationsComplete(): Bool {
		return _reachConfigurationsComplete;
	}

	/**
	 * The classes the project declares a class value may be made of from a name the compiler facts cannot read
	 * (`reflectiveClasses`): globs over qualified type names (`model.**`, `__ASSET__*`), a star within one dotted segment
	 * and a double star across segments (`Glob.qualifiedNames`). A name computed at run time and handed to
	 * `Type.resolveClass`, a producer read as a value, a producer's body the compiler spliced in — each makes a class
	 * value of a class one of the globs matches, by the qualified name of the class itself (a subtype is matched by its
	 * own). Read under `reachConfigurationsComplete` only, by the member-reach analysis behind the loop rewrites
	 * (`FactsEscapes`). Null when the key is absent: such a name may then name any class, which no escape analysis bounds.
	 */
	public function reflectiveClasses(): Null<Array<String>> {
		return _reflectiveClasses;
	}

	/**
	 * The classes the project declares a method of which a reflective read by a name the compiler facts cannot read may
	 * obtain as a value (`reflectiveMethodHolders`): globs over qualified type names, as `reflectiveClasses`. Such a read
	 * — `Reflect.field(o, name)`, `Reflect.getProperty`, a reflective member read as a value — obtains a method only off an
	 * object of a class one of the globs matches by its own qualified name (a subtype is matched by its own), or off one of
	 * those classes as a value for a static; a variable is read whatever the list says. Read under
	 * `reachConfigurationsComplete` only, by the member-reach analysis behind the loop rewrites (`FactsMethodValues`).
	 * Null when the key is absent: such a read may then obtain any method of any object it may be handed.
	 */
	public function reflectiveMethodHolders(): Null<Array<String>> {
		return _reflectiveMethodHolders;
	}

	/**
	 * The declared source roots (`resolutionRoots`) — directories whose `.hx` sources join the resolution
	 * scope so the cross-file type / inheritance checks resolve against them, without those files ever
	 * being reported or edited. Each is resolved to absolute against the config directory; an empty array
	 * when the key is absent.
	 *
	 * The name reads as "extra directories for resolution" and that is no longer all it is:
	 * this key is the ONLY channel that puts the project's OWN unlinted sources into the scope —
	 * `resolutionLibs` names installed libraries and the std joins by itself — and it feeds BOTH halves a
	 * cross-file rewrite is proved against: `ResolutionSources.projectRoots`, which the reflection scan of
	 * `unused-private` reads directly, and the library half, which `LintCommand.resolutionThunk`
	 * concatenates the same roots into and which is what the index behind `widestScopeIndex` is built from. Leave it out while
	 * declaring libs and the scope is declared, holds no file of the project, and those proofs quietly
	 * answer from the report scope again — pinned by `CrossScopeSoundnessTest.LIBS_ONLY_REGRESSIONS`,
	 * and announced by `ConfigDisagreement.warnMissingProjectRoots`.
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
	 * How many findings a TEXT `apq lint` report may list one per line before it prints a per-rule
	 * summary instead (`reportSummaryThreshold`, default `LintFormat.DEFAULT_REPORT_SUMMARY_THRESHOLD`). Zero or
	 * less never summarises. `--full` / `--summary` override it per run; json and checkstyle are
	 * never summarised. A project-level key: the run reads it off the config of its first path.
	 */
	public function reportSummaryThreshold(): Int {
		return _reportSummaryThreshold;
	}

	/**
	 * Whether `id` runs in the default set. `defaultOn` is the rule's default when its
	 * `enabled` key is absent — true for an ordinary rule, false for a `DefaultOff` rule
	 * the caller opts into. A present `enabled` value always wins.
	 */
	public function enabledFor(id: String, defaultOn: Bool = true): Bool {
		return enabledSetting(id) ?? defaultOn;
	}

	/** The `enabled` value the config states for rule `id`, or null when it states none and the rule's own default applies. */
	public function enabledSetting(id: String): Null<Bool> {
		return _rules[id]?.enabled;
	}

	/** The configured severity override for `id`, or null when unset. */
	public function severityFor(id: String): Null<Severity> {
		final rc: Null<RuleConfig> = _rules[id];
		return rc?.severity;
	}

	/**
	 * A rule-specific integer option (e.g. complexity `max`), or null when
	 * unset or non-numeric. A fractional value truncates, as it always has.
	 */
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

	/** A rule-specific string option (e.g. `import-order` `order`), or null when unset or non-string. */
	public function stringOption(id: String, key: String): Null<String> {
		return switch propOf(id, key) {
			case JString(v): v;
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
		LintDocuments.collectStrings(raw, out);
		return out;
	}

	/**
	 * The option keys the document wrote for rule `id`, sorted — `enabled` and `severity` aside, which the framework
	 * reads — so a check reading its options through one reader can say which key no option of it has.
	 */
	public function optionKeys(id: String): Array<String> {
		final rule: Null<RuleConfig> = _rules[id];
		if (rule == null) return [];
		final keys: Array<String> = [for (key in rule.props.keys()) key];
		keys.sort(Reflect.compare);
		return keys;
	}

	/**
	 * Whether a rule requiring language version `minimum` may run for this config.
	 *
	 * True when the project declares no `languageVersion` — an undeclared floor constrains
	 * nothing, which is what every existing config already means. Otherwise the declared
	 * version must be at least `minimum`, compared component-wise on the dotted numbers so
	 * `4.10` sorts above `4.9`. A version either side cannot parse is treated as no
	 * constraint rather than as a refusal: a typo must not silently switch rules off.
	 */
	public function allowsLanguageVersion(minimum: String): Bool {
		final declared: Null<String> = _languageVersion;
		return declared == null || compareVersions(declared, minimum) >= 0;
	}

	/** The declared `languageVersion`, or null when the project states no floor. */
	public function languageVersion(): Null<String> {
		return _languageVersion;
	}

	/**
	 * The framework contracts the project declares (`frameworks`) — see `FrameworkContract`. The
	 * roster is ADDITIVE: a grammar's own built-in framework still applies, so declaring Unity here
	 * never switches utest off. An empty array when the key is absent, which is every existing config.
	 */
	public function frameworks(): Array<FrameworkContract> {
		return _frameworks;
	}

	/**
	 * The type ownerships the project declares (`ownedTypes`) — see `TypeOwnership`: which types and members a layer
	 * owns, the code that owns them and why, for the `owned-types` rule. An empty array when the key is absent, which
	 * leaves the rule inert. Like every array of the chain, a nearer document's list replaces an ancestor's wholesale.
	 */
	public function ownedTypes(): Array<TypeOwnership> {
		return _ownedTypes;
	}

	/**
	 * Ready diagnostic lines for what a document in this config's chain declared under `frameworks` and
	 * this reader DROPPED or partly IGNORED: an entry that is not an object, names no `root`, nominates
	 * nothing, spells one of the three keys with the wrong type, or names a key this reader does not know.
	 *
	 * One line per FAULT, not per entry — a single entry can earn several (a wrong-typed `"root"` names the
	 * type error and then the drop it causes), and an entry with three unknown keys earns three.
	 *
	 * `discover` prints them once per config file, attributed to the document that declared it; the merged
	 * list here carries no attribution, so it is a count rather than a report. `parse` returns one
	 * document's lines without printing, because it cannot tell a probe from a real config file.
	 *
	 * A dropped entry that says nothing is indistinguishable from one that works, which is the whole hazard
	 * of a per-entry-lenient reader. The wrong-TYPED value was the last shape of it and the quietest, since
	 * the entry survives and its surviving half reads as the whole.
	 */
	public function drops(): Array<String> {
		return _drops;
	}

	/**
	 * The raw prop `key` of rule `id`, or null when the rule is unconfigured
	 * or lacks the key — the base for the typed option accessors.
	 */
	private function propOf(id: String, key: String): Null<JValue> {
		final rc: Null<RuleConfig> = _rules[id];
		return rc?.props[key];
	}

	/** The raw array prop `key` of rule `id`, or null when it is unset or not an array — the array base for the list accessors. */
	private function arrayOption(id: String, key: String): Null<Array<JValue>> {
		return switch propOf(id, key) {
			case JArray(items): items;
			case null, _: null;
		};
	}

	/**
	 * Discover the `apqlint.json` CHAIN above `path` — every one from its own directory
	 * up to the filesystem root, nearest first — and fold it into one config; an empty
	 * config (every rule enabled, no overrides) when the chain is empty.
	 *
	 * A nested document EXTENDS its ancestors and overrides only the keys it names.
	 * Replacing the nearest ancestor wholesale would be a silent loss: a
	 * document written as a few exemptions for test code would inherit neither the
	 * project's resolution scope, nor its oracle, nor the rules the root opted into
	 * — and a missing rule does not fail, it finds nothing.
	 *
	 * The merge is per KEY at the top level and per RULE inside `rules`, because
	 * "disable magic-number for tests" has to keep meaning that and nothing else;
	 * per-key again inside one rule entry, so an options-only override
	 * (`{"oversized-type": {"maxMembers": 100}}`) neither re-enables a rule an
	 * ancestor disabled nor drops the options it set. ARRAYS replace wholesale —
	 * there is no element-wise union, because a union has no way to spell a removal.
	 * A document declaring `"inherit": false` ends the chain at itself.
	 *
	 * A document the schema rejects is skipped with a diagnostic and the REST of the
	 * chain still applies: the nearest config being broken must not also throw away
	 * the project's.
	 */
	public static inline function discover(path: String): LintConfig {
		return discoverChain(path).config;
	}

	/**
	 * `discover`, plus the documents it FOLDED, nearest first — the chain as it was applied, so a
	 * document the schema rejected or an `"inherit": false` cut off is absent from it.
	 *
	 * Two directories whose chains are equal resolve to the same config, since every value a document
	 * declares is resolved against that document's own directory; that is what lets a report group
	 * files by chain rather than by directory.
	 */
	public static function discoverChain(path: String, ?documents: DocumentMemo): DiscoveredConfig {
		final chain: ConfigChain = ConfigFinder.findUpAll(path, 'apqlint.json', ConfigFinder.PROJECT_ROOT_MARKERS);
		final folded: Array<String> = [];
		var merged: Null<LintDocument> = null;
		// A document that EXISTS and cannot be read is the one outcome with no other
		// symptom: the ancestor's answer applies to a question this document already
		// answered, and nothing else says so.
		for (path in chain.unreadable) warnOnce(path, 'apq: $path could not be read — ignored, the rest of the chain still applies\n');
		for (entry in chain.documents) {
			final doc: Null<LintDocument> = LintDocuments.parseDocumentIn(documents, entry.content, Path.directory(entry.path));
			if (doc == null) {
				// A REAL config file that the schema rejects must not degrade silently — a
				// wholesale fallback quietly collapses the resolution scope and every rule
				// toggle. Once per file per process: `discover` re-runs for every linted
				// directory (the CLI memoises per directory, not per config), so an
				// unde-duplicated line would repeat N times per run.
				warnOnce(entry.path, 'apq: ${entry.path} failed to parse — ignored, the rest of the chain still applies\n');
				continue;
			}
			// A per-ENTRY drop degrades silently in exactly the way the wholesale rejection
			// above does not: the document parses, every other key applies, and the entry the
			// project wrote simply is not there. Same once-per-file-per-process ledger, and
			// attributed to the document that declared it, since a chain has several.
			if (doc.drops.length > 0) {
				final lines: Array<String> = [for (drop in doc.drops) 'apq: ${entry.path}: $drop\n'];
				warnOnce(entry.path, lines.join(''));
			}
			merged = merged == null ? doc : LintDocuments.mergeDocuments(merged, doc);
			folded.push(entry.path);
			if (doc.inherit == false) break;
		}
		final result: Null<LintDocument> = merged;
		return { config: result == null ? new LintConfig([]) : LintDocuments.fromDocument(result), chain: folded };
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
	 * The framework roster for a whole lint RUN over `files`, resolved through `resolve` — the one
	 * question every framework-aware check asks, so they cannot disagree about a member by reading the
	 * config differently.
	 *
	 * Resolved ONCE, from the first file. A scope spanning two roots with different `apqlint.json` files
	 * therefore applies the first one's roster throughout; that is deliberate, because the rules sharing
	 * this answer do not all have a per-file seam to resolve at (`unused-public-member` builds one
	 * whole-scope context before it sees a file), and a roster that differed between two of them would
	 * spare a member from one rule and delete it with its sibling.
	 *
	 * What was NOT deliberate is that such a scope said nothing about it. `ConfigDisagreement.warnRoster`
	 * names it once per run — from the CLI rather than from here, because this is called once per
	 * framework-aware RULE and its own answer costs one resolve while the diagnostic costs one per file,
	 * against a resolver that is only memoised on the CLI's side.
	 */
	public static function frameworksFor(
		resolve: Null<(String) -> LintConfig>, files: Array<{ file: String, source: String }>
	): Array<FrameworkContract> {
		return files.length == 0 ? [] : resolveWith(resolve, files[0].file).frameworks();
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
	public static function parse(content: String, ?baseDir: String, ?documents: DocumentMemo): LintConfig {
		final doc: Null<LintDocument> = LintDocuments.parseDocumentIn(documents, content, baseDir);
		return doc == null ? new LintConfig([]) : LintDocuments.fromDocument(doc);
	}

	/** Guarded stderr write — mirrors `Cli.stderr` (`#if sys` alone is false on hxnodejs). */
	private static function stderr(s: String): Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
	}

	/**
	 * Write `message` to stderr the first time `configPath` reports anything —
	 * the once-per-file-per-process ledger `discover`'s two diagnostics share.
	 */
	private static function warnOnce(configPath: String, message: String): Void {
		if (warnedConfigs.contains(configPath)) return;
		warnedConfigs.push(configPath);
		stderr(message);
	}

	/**
	 * `a` against `b` as dotted version numbers: negative when `a` is older, 0 when equal,
	 * positive when newer. A missing component reads as 0 (`4` == `4.0`), and a component
	 * that is not a number makes the whole comparison answer 0 — see `allowsLanguageVersion`
	 * for why an unreadable version must not refuse.
	 */
	private static function compareVersions(a: String, b: String): Int {
		final left: Array<String> = a.split('.');
		final right: Array<String> = b.split('.');
		final count: Int = left.length > right.length ? left.length : right.length;
		for (i in 0...count) {
			final lv: Null<Int> = i < left.length ? Std.parseInt(left[i].trim()) : 0;
			final rv: Null<Int> = i < right.length ? Std.parseInt(right[i].trim()) : 0;
			if (lv == null || rv == null) return 0;
			if (lv != rv) return lv - rv;
		}
		return 0;
	}

}
