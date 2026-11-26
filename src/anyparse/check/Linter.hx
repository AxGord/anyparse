package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.ConfigNoting;
import anyparse.check.Check.CrossFileAnchored;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.GraphScoped;
import anyparse.check.Check.LanguageBound;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.Check.Supersedes;
import anyparse.check.Check.VersionGated;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.LintConfig.ConfigNote;
import anyparse.core.PhaseTimings;
import anyparse.macro.RuleDiscovery;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.RunLedger;
import anyparse.runtime.Span;

using Lambda;

/**
 * Runs a set of `Check`s over a file set and concatenates their
 * violations. Doubles as the built-in check registry: `builtins()` is the
 * default check set the `lint` CLI runs, and `byId` resolves a `--rule`
 * selection against it. A second registry abstraction is deliberately not
 * introduced — there is one check today and the registry is a one-line
 * factory; it grows into a richer form only when a real config / plugin
 * source of checks exists.
 */
@:nullSafety(Strict)
final class Linter {

	/**
	 * The default check set: a fresh instance of every built-in rule, in the registry order `RuleDiscovery` derives.
	 * A new rule joins by being a concrete `RuleBase` class of the `anyparse.check` packages; a rule whose fix must run
	 * before or after another one says so with `@:lintBefore` / `@:lintAfter` on itself.
	 */
	public static function builtins(): Array<Check> {
		return RuleDiscovery.builtins();
	}

	/** The built-in check whose `id()` equals `id`, or null. */
	public static function byId(id: String): Null<Check> {
		return builtins().find(c -> c.id() == id);
	}

	/**
	 * Whether `check` runs under `config`: the config's word for its id or its category (`LintConfig.switchFor`),
	 * else its own default — off for a `DefaultOff` rule.
	 */
	public static function enabledBy(config: LintConfig, check: Check): Bool {
		return config.enabledFor(check.id(), !(check is DefaultOff), check.category());
	}

	/**
	 * Whether `check` runs on the grammar `GrammarPlugin.langName()` calls `lang`: every check does unless it is
	 * `LanguageBound` to other grammars.
	 */
	public static function runsOn(check: Check, lang: String): Bool {
		return !(check is LanguageBound) || (cast check: LanguageBound).languages().contains(lang);
	}

	/**
	 * Every registered check that declares a `VolatileMessage`, as rule id -> its
	 * `messageIdentity`. The map `apq lint-diff` keys its findings through.
	 *
	 * Built by ASKING the registry, never by naming rules: a rule whose message quotes a
	 * source coordinate joins by implementing the interface, and no consumer is edited. The
	 * seam replaces a hand-maintained pair of rule ids inside `LintDiff`, which could only
	 * ever list the rules someone had already been burned by — and which had no way to say
	 * that ONE number in a message drifts while its neighbour is the finding.
	 *
	 * A fresh `builtins()` per call rather than a cached map: a process-scoped cache is the
	 * global mutable state this project refuses, and a `lint-diff` run calls this ONCE —
	 * `Cli.runLintDiff` hoists the map above both `tally` calls, so the cost is one registry
	 * construction per process.
	 */
	public static function messageIdentities(): Map<String, (String) -> String> {
		final out: Map<String, (String) -> String> = [];
		for (check in builtins()) if (check is VolatileMessage) {
			final volatileMessage: VolatileMessage = cast check;
			// A real closure, not the bare interface-method reference: hxcpp lowers that
			// to a dynamic field read whose type StringMap.set cannot pick an overload for.
			out[check.id()] = message -> volatileMessage.messageIdentity(message);
		}
		return out;
	}

	/**
	 * Every registered check as rule id -> the option keys it accepts, none for a check that does not declare `OptionKeyed`:
	 * what `LintConfig.discover` is handed to say a key a rule's entry names and the rule does not read, and a `rules` id
	 * no check has.
	 *
	 * Built by asking the registry, never by naming rules, and rebuilt per call rather than cached: a process-scoped table
	 * is the global mutable state this project refuses, so a run hoists the one map it passes down.
	 */
	public static function acceptedOptions(): Map<String, Array<String>> {
		final out: Map<String, Array<String>> = [];
		for (check in builtins()) out[check.id()] = check is OptionKeyed ? (cast check: OptionKeyed).acceptedOptions() : [];
		return out;
	}

	/**
	 * Every finding `checks` produce over `files`, with the central REIFICATION and inline-SUPPRESSION
	 * gates applied — the ONE entry point through which a `Check.run` result reaches the rest of the
	 * tool.
	 *
	 * That it is one entry point is the whole design. A finding inside a `macro …` quotation must be
	 * dropped for every check (see `ReificationScan`), and a gate written once per consumer is a rule
	 * each new consumer has to remember: two of them — `FixVerifier.verify` and `Cli`'s
	 * oracle-assisted batch — already existed unnoticed when the gate was first added, and were found
	 * by measuring rather than by reading. Both now come through here, as does `run` itself, so the
	 * filter cannot disagree between them and a new consumer inherits it by using the obvious call.
	 *
	 * A `// noqa` / `CHECKSTYLE:OFF` directive (see `Suppression`) is the same kind of gate and lives
	 * here for the same reason. It used to sit in `run` alone, so the report honoured it and every
	 * `--fix` path ignored it: a `noqa`-carrying line was reported clean and rewritten anyway, which
	 * is the exact failure the suppression mechanism exists to prevent — the user writes it BECAUSE
	 * the rule is wrong there. `run` still adds the severity overrides on top.
	 *
	 * The per-file config gates are the third (`gatedPerFile`), applied whenever a resolver is given, and they live
	 * here for the same reason: every path that WRITES a fix reads its findings through this function. The
	 * `languageVersion` gate always holds — it is a correctness limit, and a fix past it does not compile. ENABLEMENT
	 * defaults the inverse of `run`'s on purpose, so a caller that forgets the flag writes nothing a config switched
	 * off; `run` and the fix verifiers pass the run's own `applyEnablement`, which an explicit `--rule` selection
	 * turns off for the report and every fix alike. A `CrossFileAnchored` check is handed the same per-file answer
	 * before it runs, so it anchors each finding where the finding survives. `narrow`, when given, withholds findings after
	 * those gates and BEFORE supersession: a finding the caller withholds must not take the finding it supersedes with it.
	 */
	public static function collect(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, checks: Array<Check>, ?resolveConfig: (String) -> LintConfig,
		applyEnablement: Bool = true, ?narrow: (Array<Violation>) -> Array<Violation>
	): Array<Violation> {
		final resolve: Null<(String) -> LintConfig> = resolveConfig;
		for (check in checks) if (check is CrossFileAnchored)
			(cast check: CrossFileAnchored).setReportable(resolve == null ? null : reportableFor.bind(check, resolve, applyEnablement));
		final raw: Array<Violation> = [ for (check in checks) for (violation in runGated(check, files, plugin, resolveConfig)) violation ];
		final unquoted: Array<Violation> = ReificationScan.withoutQuoted(raw, files, plugin, ReificationScan.exemptIdsOf(checks));
		final kept: Array<Violation> = Suppression.apply(unquoted, files, plugin.lexicalRegions);
		final enabled: Array<Violation> = resolveConfig == null ? kept : gatedPerFile(kept, checks, resolveConfig, applyEnablement);
		final gated: Array<Violation> = resolveConfig == null ? enabled : ExcludedScope.without(enabled, files, plugin, resolveConfig);
		return withoutSuperseded(narrow == null ? gated : narrow(gated), checks);
	}

	/**
	 * Run each check in `checks` (default: `builtins()`) over `files` and
	 * return all violations, check by check in registry order. A check
	 * must be skip-parse tolerant (see `Check`); the linter does not catch
	 * per-check exceptions. `ConfigAware` checks receive `resolveConfig`
	 * (or null) before running, so they read their per-file options through it.
	 *
	 * `resolveConfig` maps a file path to the `apq.json` in effect there
	 * (walk-up discovered, per-directory memoised by the caller): each finding
	 * is remapped to its own file's configured severity, and — ONLY when
	 * `applyEnablement` is true — DROPPED when that file disables its rule. A
	 * null resolver leaves every finding untouched.
	 *
	 * `applyEnablement` defaults to FALSE: a programmatic caller passing a
	 * resolver for severity/options is NOT silently robbed of findings whose
	 * rule a config disables (the trap when it defaulted true) — matching
	 * `--rule` semantics, where an explicitly selected check runs regardless
	 * of `enabled`. The CLI's non-`--rule` path passes true explicitly to keep config-disabled rules
	 * out of a full report. `narrow` is `collect`'s: it withholds findings before supersession.
	 */
	public static function run(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?checks: Array<Check>,
		?resolveConfig: (String) -> LintConfig, applyEnablement: Bool = false, ?narrow: (Array<Violation>) -> Array<Violation>,
		?configNotes: Array<ConfigNote>
	): Array<Violation> {
		final active: Array<Check> = checks ?? builtins();
		// Parse each file once and share the trees across all checks — each check
		// parses independently otherwise, so N checks over M files is N*M parses.
		final cached: GrammarPlugin = plugin is CachingGrammarPlugin ? plugin : new CachingGrammarPlugin(plugin);
		// Thread the caller's memoised per-file config resolver into the option-reading
		// checks so they don't re-walk ancestor dirs + re-parse the JSON per file; a null
		// resolver resets them to their own `LintConfig.discover` fallback.
		for (check in active) if (check is ConfigAware) (cast check: ConfigAware).setConfigResolver(resolveConfig);
		// A null `configNotes` resets a check reused from an earlier run, so its diagnostics never land in an array nobody says.
		for (check in active) if (check is ConfigNoting) (cast check: ConfigNoting).setConfigNotes(configNotes);
		// `collect` has already applied the reification, inline-suppression and (unless an explicit
		// --rule selection bypasses it) per-file enablement gates.
		final out: Array<Violation> = collect(files, cached, active, resolveConfig, applyEnablement, narrow);
		if (resolveConfig == null) return out;
		for (violation in out) {
			final sev: Null<Severity> = resolveConfig(violation.file).severityFor(violation.rule);
			if (sev != null) violation.severity = sev;
		}
		return out;
	}

	/**
	 * Says the config diagnostics `checks` collected into `notes` during a `run` through `ledger`, and detaches the
	 * array from them: a later `fix` or direct `run` with no notes of its own falls back to `ConfigNotes`' stderr line
	 * instead of pushing into an array nobody says again.
	 */
	public static function sayConfigNotes(
		checks: Array<Check>, notes: Array<ConfigNote>, ledger: RunLedger, write: (String) -> Void
	): Void {
		ConfigNotes.say(ledger, notes, write);
		for (check in checks) if (check is ConfigNoting) (cast check: ConfigNoting).setConfigNotes(null);
	}

	/**
	 * Answers `body` with `checks` collecting their config diagnostics into one array the whole time, then says it through
	 * `ledger` and detaches it (`sayConfigNotes`): for a phase that runs checks outside `run` — a fix verification, an
	 * oracle-assisted pass — whose reads would otherwise find no notes and fall back to `ConfigNotes`' stderr line.
	 */
	public static function sayingConfigNotes<T>(checks: Array<Check>, ledger: RunLedger, write: (String) -> Void, body: () -> T): T {
		final notes: Array<ConfigNote> = [];
		for (check in checks) if (check is ConfigNoting) (cast check: ConfigNoting).setConfigNotes(notes);
		final answer: T = body();
		sayConfigNotes(checks, notes, ledger, write);
		return answer;
	}

	/**
	 * `found` without each finding a `Supersedes` check in `checks` replaces: one of a rule it names, starting in the same file at
	 * the same offset as one of ITS surviving findings. A run holding no such check returns `found` itself.
	 */
	public static function withoutSuperseded(found: Array<Violation>, checks: Array<Check>): Array<Violation> {
		final replaced: Map<String, Array<String>> = [
			for (check in checks) if (check is Supersedes) check.id() => (cast check: Supersedes).supersedes()
		];
		if (!replaced.keys().hasNext()) return found;
		final claimed: Array<String> = [];
		for (v in found) {
			final ids: Null<Array<String>> = replaced[v.rule];
			final span: Null<Span> = v.span;
			// A finding without a span anchors nothing, so it replaces nothing.
			if (ids != null && span != null) for (id in ids) claimed.push(supersessionKey(id, v.file, span));
		}
		return claimed.length == 0 ? found : [ for (v in found) if (!claimed.contains(supersessionKey(v.rule, v.file, v.span))) v ];
	}

	/** The identity `withoutSuperseded` compares findings by: rule, file and start offset (none for a finding without a span). */
	private static inline function supersessionKey(rule: String, file: String, span: Null<Span>): String {
		return '$rule\t$file\t${span == null ? -1 : span.from}';
	}

	/**
	 * `found` without the findings whose OWN file's config gates their rule off (`passesGates`).
	 *
	 * Inside `collect` rather than beside the report, because a finding that survives here is one some path WRITES: the
	 * fix loop, the risky verifier and the oracle-assisted phase all take their findings from `collect`, and a gate kept
	 * in `run` alone let a risky fix rewrite a file whose config disabled the rule.
	 */
	private static function gatedPerFile(
		found: Array<Violation>, checks: Array<Check>, resolveConfig: (String) -> LintConfig, applyEnablement: Bool
	): Array<Violation> {
		final byId: Map<String, Check> = [ for (c in checks) c.id() => c ];
		return found.filter(violation -> {
			final config: LintConfig = resolveConfig(violation.file);
			final check: Null<Check> = byId[violation.rule];
			check != null ? passesGates(check, config, applyEnablement) : !applyEnablement || config.enabledFor(violation.rule, true);
		});
	}

	/** `passesGates` for `check` in `file`, asked of `file`'s own config — the answer a `CrossFileAnchored` check anchors by. */
	private static function reportableFor(check: Check, resolve: (String) -> LintConfig, applyEnablement: Bool, file: String): Bool {
		final config: LintConfig = resolve(file);
		return passesGates(check, config, applyEnablement) && !ExcludedScope.excludesFile(config, check.id(), file);
	}

	/**
	 * Whether a finding of `check` survives `config`: never past the file's declared `languageVersion` (see
	 * `Check.VersionGated`), and — when `applyEnablement` — only where the rule is enabled, a `DefaultOff` rule only
	 * where the file opts in.
	 */
	private static function passesGates(check: Check, config: LintConfig, applyEnablement: Bool): Bool {
		final minVersion: Null<String> = check is VersionGated ? (cast check: VersionGated).minLanguageVersion() : null;
		return (minVersion == null || config.allowsLanguageVersion(minVersion)) && (!applyEnablement || enabledBy(config, check));
	}

	/**
	 * The files `check` scans: all of them, except that a `FileGated` check gets only those its
	 * `skipReason` accepts under each file's own config — the gate `EffectiveRules` reports, applied
	 * where every `Check.run` result enters the tool.
	 */
	private static function scannedBy(
		check: Check, files: Array<{ file: String, source: String }>, resolveConfig: Null<(String) -> LintConfig>
	): Array<{ file: String, source: String }> {
		if (!(check is FileGated)) return files;
		final gated: FileGated = cast check;
		final reported: Array<{ file: String, source: String }> = files.filter(f ->
			gated.skipReason(f.file, LintConfig.resolveWith(resolveConfig, f.file)) == null
		);
		if (!(check is GraphScoped) || reported.length == 0) return reported;
		final scoped: GraphScoped = cast check;
		return files.filter(f -> scoped.scanSkipReason(f.file, LintConfig.resolveWith(resolveConfig, f.file)) == null);
	}

	/**
	 * `check` run over the files `scannedBy` hands it, without a `GraphScoped` check's findings in the files its report
	 * gate refuses — the half of the gate `scannedBy` does not apply to such a check. A finding naming no file (a
	 * malformed option) stays.
	 */
	private static function runGated(
		check: Check, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, resolveConfig: Null<(String) -> LintConfig>
	): Array<Violation> {
		if (!runsOn(check, plugin.langName())) return [];
		final found: Array<Violation> = PhaseTimings.measure(
			'rule ${check.id()}', () -> check.run(scannedBy(check, files, resolveConfig), plugin)
		);
		if (!(check is GraphScoped)) return found;
		final gated: GraphScoped = cast check;
		return found.filter(v -> v.file == '' || gated.skipReason(v.file, LintConfig.resolveWith(resolveConfig, v.file)) == null);
	}

}
