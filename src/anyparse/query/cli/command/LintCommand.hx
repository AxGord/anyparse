package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.ConfigDisagreement;
import anyparse.check.LintConfig;
import anyparse.check.LintDocuments;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.common.design.ThreadSafety;
import anyparse.check.facts.TypedFactsProbe;
import anyparse.check.oracle.ReachDefinesProbe;
import anyparse.core.PhaseTimings;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.ExitCode.*;
import anyparse.query.cli.CliArgs.ResolvedInputs;
import haxe.io.Path;

using Lambda;

/**
 * The `lint --fix` check sets, split by how each is applied: `risky` is verified against the compiler oracle,
 * `safe` runs in the unverified fixpoint loop, and `safe` in turn splits into `activeScope` (re-linted only
 * over the files a prior pass changed) and `fullScope` (re-linted over the whole file set every pass).
 */
typedef CheckPartition = {
	var risky: Array<Check>;
	var safe: Array<Check>;
	var activeScope: Array<Check>;
	var fullScope: Array<Check>;
};

/**
 * The `--range` windows: one or more 1-based, inclusive LINE spans, and the only scope the
 * lint layer narrows to below file granularity. Several spans serve a write that changed
 * several regions: their hull would also hold the untouched code between them.
 *
 * A finding is kept when the line its span STARTS on falls inside one; a finding carrying
 * no span at all is dropped, because no coordinate means no proof of membership. The
 * line is measured against the file as the run reads it AT THAT MOMENT, which matters
 * only under `--fix`: the fixed-point loop re-reads a rewritten file on the next pass,
 * so a fix that changes the file's line count shifts what a later pass sees through
 * the same window. For the window this exists to serve — the lines a write op just
 * changed — that drift is bounded, and this is a narrowing net rather than a
 * correctness gate; for an exact one-shot, pair `--range` with `--rule`.
 *
 * What it narrows is FINDINGS, never EDITS. A check whose fix is atomic across sites
 * (`unused-parameter` rewrites the signature AND every call-site argument) still
 * writes wherever its own fix says, off a finding inside the window. Clipping that
 * would leave the file broken, which is the opposite of a safety net.
 */
typedef LintRange = Array<LineWindow>;

/** One `--range` span: a 1-based, inclusive pair of line numbers. */
typedef LineWindow = {
	final from: Int;
	final to: Int;
};

/**
 * Parsed options for `apq lint` — `lang`, `flat`, `includeInfo`, `fix`, the `failOn` severity, output `format`,
 * `ruleFilters`, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef LintOpts = {
	var lang: String;
	var flat: Bool;
	var includeInfo: Bool;
	var fix: Bool;
	var noOracle: Bool;

	/** `--fix-probes` — the typechecks the `--fix` safe-pass net may spend isolating culprits in one run. */
	var fixProbes: Int;
	var failOn: Null<Severity>;
	var format: String;
	var ruleFilters: Array<String>;

	/**
	 * The `--category` ids, each a known `RuleCategory`: a run keeps only the rules of these categories the config
	 * enables, where `--rule` force-runs what it names, so the two never combine.
	 */
	var categoryFilters: Array<String>;
	var inputSpecs: Array<String>;
	// The `--range` line window, or null for the whole scope. See `LintRange`.
	var range: Null<LintRange>;

	/**
	 * The `--baseline` snapshot path, or null. A run given one reports only the findings the
	 * snapshot does not already carry and rewrites the snapshot with everything it found.
	 */
	var baseline: Null<String>;

	/**
	 * `--verbose` — bring back the accounting a quiet run withholds: the `--fix` rule census
	 * and the `--no-oracle` net notice. It adds output, never behaviour.
	 */
	var verbose: Bool;

	/**
	 * `--explain-long` — after the findings, say why `thread-safety` holds each lock long (`LongLockExplain`). It adds
	 * output, never a finding.
	 */
	var explainLong: Bool;

	/**
	 * How the TEXT report is laid out: `true` = `--summary` (per-rule summary), `false` = `--full`
	 * (every finding), null = the `reportSummaryThreshold` decides. See `LintReport.summarises`.
	 */
	var summary: Null<Bool>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag/value -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq lint` — run analysis checks and report violations (e.g. unused-import).
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class LintCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'lint';
	}

	public function summary(): String {
		return 'Run analysis checks and report violations (e.g. unused-import)';
	}

	public function flags(): CliFlags {
		return new CliFlags(
			[
				'--all',
				'--explain-long',
				'--fix',
				'--flat',
				'--full',
				'--list-rules',
				'--no-oracle',
				'--summary',
				'--verbose',
				'-a'
			],
			[
				'--baseline',
				'--category',
				'--fail-on',
				'--fix-probes',
				'--format',
				'--range',
				'--rule'
			]
		);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		final status: Int = PhaseTimings.measure('lint', runLint.bind(args));
		PhaseTimings.report(CliIo.stderr);
		return status;
	}

	public function usage(): Void {
		LintArgs.printLintUsage();
	}

	/**
	 * `apq lint <scope> [--rule <id>]... [--all] [--flat] [--range <a>:<b>] [--lang <name>]`
	 * — run the analysis checks over `<scope>` (one or more file/dir/glob
	 * specs) and report violations grouped by file, reusing the walker
	 * reporter (`Text.renderViolations`). `--rule` selects a subset of the
	 * built-in checks by id (repeatable); the default runs all of them.
	 *
	 * Findings go to stdout grouped per file; a severity breakdown goes to
	 * stderr so stdout stays a clean list. `Info` advisories (e.g.
	 * unverifiable wildcard / `using` imports) are hidden unless `--all` is
	 * given, but always counted in the summary. The exit code is success
	 * regardless of findings — `lint` is a report, like `symbols`.
	 *
	 * Public because a write op's `--fix` re-enters the lint layer through here
	 * (see `CliEdit.finishEdit`). The argument is argv, so such a caller re-uses
	 * every bit of setup this function does — check resolution, per-file config
	 * discovery, the resolution scope, the oracle keys — instead of assembling a
	 * second copy of it that would drift.
	 */
	public static function runLint(args: Array<String>): Int {
		final o: LintOpts = LintArgs.parseLintArgs(args);
		if (o.errExit != null) return o.errExit;

		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq lint: expected <scope> (one or more file/dir/glob specs)\n');
			LintArgs.printLintUsage();
			return EXIT_USAGE;
		}

		final checks: Null<Array<Check>> = LintArgs.resolveLintChecks(o.ruleFilters, o.categoryFilters);
		if (checks == null) return EXIT_USAGE;

		final io: ResolvedInputs = CliArgs.resolveInputPaths(o.lang, o.inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq lint: ${CliArgs.quotedSpecs(o.inputSpecs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;
		final optionError: Null<Int> = LintArgs.optionScopeError(o, paths, checks, plugin.langName());
		if (optionError != null) return optionError;

		final files: Array<{ file: String, source: String }> = [];
		final sourceOf: Map<String, String> = [];
		for (path in paths) {
			final fileSource: String = try {
				CliIo.readSourceForParse(path);
			} catch (exception: Exception) {
				CliIo.stderr('apq lint: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			files.push({ file: path, source: fileSource });
			sourceOf[path] = fileSource;
		}

		// Per-file config: discover an apq.json by walking up from EACH linted
		// file's directory, memoised per directory so a large run walks the tree once
		// per directory, not once per file. Mirrors the per-file hxformat.json the
		// writer-emit ops discover; a single-config project resolves the same config
		// for every file, so behaviour there is unchanged.
		final configByDir: Map<String, LintConfig> = [];
		function resolveConfig(file: String): LintConfig {
			final dir: String = Path.directory(file);
			final cached: Null<LintConfig> = configByDir[dir];
			if (cached != null) return cached;
			final discovered: LintConfig = LintConfig.discover(file);
			configByDir[dir] = discovered;
			return discovered;
		}
		// An explicit --rule selection bypasses `enabled:false` (existing semantics);
		// otherwise a check runs when it is enabled for at least one file, and
		// `Linter.run` drops its findings on the files that disable it.
		final applyEnablement: Bool = o.ruleFilters.length == 0;
		// Enablement is asked per DISTINCT config, not per file: every file of a directory gets the same memoised config,
		// and the per-file form asked every check once per file. `paths` is the run's
		// file order, the order every later per-file question discovers configs in, so each once-per-document config
		// warning prints where it did.
		final fileConfigs: Array<LintConfig> = LintDocuments.distinctConfigs(paths, resolveConfig);
		final activeChecks: Array<Check> = applyEnablement ? [
			for (c in checks) if (fileConfigs.exists(config -> Linter.enabledBy(config, c))) c
		] : checks;

		// Resolution scope: the UNION of `resolutionRoots` (explicit dirs) and `resolutionLibs`
		// (haxelib names) across every discovered config, PLUS the auto-discovered Haxe std, which
		// joins unconditionally so that whether a std type resolves never depends on the project
		// happening to declare an unrelated library. Their `.hx` sources join the SymbolIndex the
		// cross-file checks resolve against — never reported, never edited — read lazily on first
		// demand, and the lib names are resolved to dirs via `haxelib libpath` only then.
		// So the scope is NOT opt-in any more: it is null only when the project declares neither key
		// AND no std is discoverable — a machine without Haxe, or one that declined the std via
		// `APQ_NO_STD` / a config `"resolutionStd": false`. A project with neither key still spawns
		// no haxelib; it pays one memoised `which haxe` probe for the whole process, which is what
		// its inertness guarantee now amounts to. `declared` records which of the two ways the scope
		// came to exist, for the consumers that must tell them apart.
		final resolutionRoots: Array<String> = unionConfigStrings(paths, resolveConfig, c -> c.resolutionRoots());
		final resolutionLibs: Array<String> = unionConfigStrings(paths, resolveConfig, c -> c.resolutionLibs());
		final unconfigured: Null<ResolutionScope> = resolutionThunk(
			files, resolutionRoots, resolutionLibs, paths.foreach(p -> resolveConfig(p).resolutionStd())
		);
		// Compiler oracle (opt-in via apq.json `compilerOracle`): a project-level
		// setting, so the config resolved for the first linted file carries it for the
		// whole run — every configuration it declares is typechecked as ground truth below, and a
		// project with conditional compilation needs more than one. That stays; what it owes
		// the reader is a word when the scope spans roots that name DIFFERENT builds, since
		// every risky and oracle-assisted verdict below is then taken against a build the
		// second root never declared.
		warnScopeNotices(activeChecks, resolveConfig, paths, o.noOracle);
		final oracleConfig: Null<LintConfig> = paths.length > 0 ? resolveConfig(paths[0]) : null;
		final oracles: Array<OracleConfig> = LintOracleRun.oraclesOf(oracleConfig, o.noOracle, !o.fix, files, plugin);
		final early: Null<FactsProbe> = LintOracleRun.earlyFacts(unconfigured != null, oracles, o);
		final ahead: AheadBuilds = { probe: null };
		final reflective: Null<Array<String>> = LintOracleRun.declaredBound(
			paths, resolveConfig, c -> c.reflectiveClasses(), LintOracleRun.REFLECTIVE_CLASSES, 'a computed class name may name any class'
		);
		final holders: Null<Array<String>> = LintOracleRun.declaredBound(
			paths, resolveConfig, c -> c.reflectiveMethodHolders(), LintOracleRun.REFLECTIVE_METHOD_HOLDERS,
			'a computed member name may obtain any method'
		);
		final resolution: Null<ResolutionScope> = LintOracleRun.withCompilerFacts(
			LintOracleRun.withReachConfigurations(
				unconfigured, oracles, o.noOracle, LintOracleRun.reachComplete(paths, resolveConfig), ahead, reflective, holders,
				paths.exists(path -> resolveConfig(path).reachConfigurationsComplete())
			),
			oracles, early, reflective, holders, ahead, o
		);

		if (o.fix)
			return LintOracleRun.endingCompiles(
				early, ahead, oracles,
				() ->
					LintFixDriver.runLintFix(
						files, activeChecks, plugin, resolveConfig, applyEnablement, resolution, LintFixVerify.verifiable(oracles),
						o.noOracle, o.range, o.verbose, o.fixProbes
					)
			);

		// Report mode only — the fix path returned above, so this pass never runs redundantly in a
		// --fix run. The resolution scope joins the checks' SymbolIndex; findings stay in the report
		// files. ONE wrapper serves both halves of the pass: the address annotation in the report
		// reads the trees the checks just parsed out of its cache instead of parsing them again.
		final cached: CachingGrammarPlugin = wrapResolution(plugin, resolution);
		final explainer: Null<ThreadSafety> = LintExplainLong.explainer(activeChecks, o.explainLong);
		final found: Array<Violation> = LintReport.withinRange(
			Linter.run(files, cached, activeChecks, resolveConfig, applyEnablement), f -> sourceOf[f], o.range
		);
		// One narrowing, applied before everything downstream: the report, the severity summary and
		// `--fail-on` all speak about the SAME set, so a caller can gate on "my edit introduced
		// something" without the exit code and the printed lines disagreeing. The refreshed
		// snapshot is the full set (`found`), not this one — see `baselineDelta`.
		final all: Array<Violation> = LintReport.baselineDelta(found, o.baseline, sourceOf);

		final shown: Array<Violation> = LintReport.reportedViolations(all, o.includeInfo, o.format);
		LintReport.reportFindings(
			o, paths, all, shown, sourceOf, cached, oracleConfig, LintFixVerify.unparseableFiles(files, cached), explainer
		);

		// `--no-oracle` skips the typecheck entirely rather than faking its verdict:
		// the note below says the compiler was not asked, so nothing downstream can
		// read an unproved run as a proved one. It exists because the oracle is a
		// PROJECT-WIDE typecheck regardless of how narrow the lint scope is — nearly the
		// whole of a single-file run, the inner loop's largest single tax.
		final oracleExit: Null<Int> = o.noOracle
			? LintFixVerify.oracleSkippedNote(oracles)
			: LintFixVerify.reportModeOracle(oracles, paths, oracleConfig?.compilerOracleServer() ?? false);
		LintOracleRun.endCompiles(early, ahead, oracles);
		if (oracleExit != null) return oracleExit;

		final failOn: Null<Severity> = o.failOn;
		if (failOn != null) {
			final threshold: Int = (cast failOn: Int);
			for (v in all) if ((cast v.severity: Int) <= threshold) return EXIT_RUNTIME;
		}
		return EXIT_OK;
	}

	/**
	 * The resolution-scope thunk for `roots` (explicit dirs) plus `libNames` (haxelib names, resolved
	 * to source dirs on first demand via `haxelib libpath`): on first call it resolves the lib names,
	 * globs every root's `.hx` and reads their sources once (memoised), returning the LIVE report
	 * `files` and those library entries as the two SEPARATE halves of a `ResolutionSources` — separate
	 * because only the library half may enter `CachingGrammarPlugin`'s process-scoped parse tier.
	 * Library entries are deduped against the report paths, so a file the run lints is never also
	 * indexed as library. When `stdEnabled`, the auto-discovered Haxe std joins that SAME scope
	 * unconditionally, so whether a std type resolves never depends on the project happening to declare
	 * an unrelated library.
	 *
	 * The result carries `declared` — true when `roots` or `libNames` is non-empty — so a consumer can
	 * tell a project-declared scope from one that exists only because a std was found.
	 *
	 * Null only when `roots` and `libNames` are BOTH empty AND no std joins: either `stdEnabled` is
	 * false (an `apq.json` `"resolutionStd": false`) or `StdResolver.stdDir()` finds none (no Haxe
	 * on the machine, or `APQ_NO_STD` declining it). The short-circuit order matters: with either key
	 * declared, `StdResolver.stdDir()` is never reached, so those projects stay byte-identical. A
	 * project declaring NEITHER key pays one memoised `which haxe` probe (`StdResolver.stdDir` computes
	 * once per process) — so its inertness guarantee is "spawns no haxelib; one `which haxe` at most",
	 * not "spawns nothing".
	 *
	 * Reading the `files` array live keeps the report portion current across `--fix` passes; the
	 * library portion is immutable.
	 */
	public static function resolutionThunk(
		files: Array<{ file: String, source: String }>, roots: Array<String>, libNames: Array<String>, stdEnabled: Bool
	): Null<ResolutionScope> {
		final declared: Bool = roots.length > 0 || libNames.length > 0;
		if (!declared && !(stdEnabled && StdResolver.stdDir() != null)) return null;
		// Dedup by the SYMLINK-RESOLVED absolute path: a library glob path is always absolute, a report
		// path keeps the CLI-arg spelling (often relative), so a raw-string compare misses an overlap and
		// indexes the shared file TWICE — duplicate declarations that trip the resolver's ambiguity gate
		// and silently suppress the cross-file finding. Normalise both sides; the report file keeps its
		// original spelling in `files` (report/edit scope), the overlapping library copy is dropped.
		// `absolutePath` alone is NOT enough, and the gap is not exotic: it only prefixes the CWD, so a
		// root reached through a symlink (a `resolutionRoots` entry naming a linked tree, a report path
		// spelled through macOS's `/tmp` -> `/private/tmp`) keeps a different string for the same file
		// and the whole dedup misses. `FileIdentity.realPath` resolves the link.
		// A MAP, not an array: the library always carries the std files, so a linear `contains` over
		// the report would be one string compare per (report x library) pair, for a lookup that is
		// answered in one hash.
		final reportPaths: Map<String, Bool> = [for (f in files) FileIdentity.realPath(f.file) => true];
		var projectRoots: Null<Array<{ file: String, source: String }>> = null;
		var library: Null<Array<{ file: String, source: String }>> = null;
		var declaredLibrary: Null<Array<{ file: String, source: String }>> = null;
		var rootsMatched: Bool = false;
		var rootsAllMatched: Bool = false;
		return {
			declared: declared,
			sources: () -> {
				final memoisedRoots: Null<Array<{ file: String, source: String }>> = projectRoots;
				final memoised: Null<Array<{ file: String, source: String }>> = library;
				if (memoisedRoots == null || memoised == null) {
					final read: {
						files: Array<{ file: String, source: String }>,
						matched: Bool,
						allMatched: Bool
					} = readResolutionRoots(roots, reportPaths);
					final rootFiles: Array<{ file: String, source: String }> = read.files;
					rootsMatched = read.matched;
					rootsAllMatched = read.allMatched;
					projectRoots = rootFiles;
					// The library half stays the WHOLE read-only scope — project roots included — so the
					// process-scoped parse tier keeps promoting exactly what it did, and it stays ONE
					// memoised array instance (`SharedParseTier.promote` keys on the instance).
					final libraryRead: {
						declared: Array<{ file: String, source: String }>,
						std: Array<{ file: String, source: String }>
					} = readResolutionLibrary(libNames, stdEnabled, reportPaths, rootFiles);
					declaredLibrary = rootFiles.concat(libraryRead.declared);
					library = rootFiles.concat(libraryRead.declared).concat(libraryRead.std);
				}
				final rootFiles: Array<{ file: String, source: String }> = projectRoots ?? [];
				final libFiles: Array<{ file: String, source: String }> = library ?? [];
				return {
					report: files,
					projectRoots: rootFiles,
					library: new LibrarySources(libFiles),
					declaredLibrary: new LibrarySources(declaredLibrary ?? []),
					rootsMatched: rootsMatched,
					rootsAllMatched: rootsAllMatched
				};
			}
		};
	}

	/**
	 * Wrap `plugin` in a `CachingGrammarPlugin`, carrying `resolution` when a scope reached this run.
	 * A scope is absent only when the project declares neither resolution key and no Haxe std is
	 * discoverable (no Haxe on the machine, or the std declined via `APQ_NO_STD` /
	 * `"resolutionStd": false`) — not merely when none is configured. The WRAPPER is unconditional
	 * either way: `resolutionIndexOf` gates on `hasAnyResolutionScope`, so a scopeless wrapper answers
	 * exactly what the bare plugin did, and the memoized parses serve the checks and the report's
	 * address annotation regardless of whether anything cross-file resolves.
	 */
	public static function wrapResolution(plugin: GrammarPlugin, resolution: Null<ResolutionScope>): CachingGrammarPlugin {
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(plugin);
		if (resolution != null) host.setResolutionScope(resolution);
		return host;
	}

	/**
	 * The three scope-level `apq.json` diagnostics, once per run, from the one place that can
	 * afford them and can tell whether the run consults each setting.
	 *
	 * All three ask their question of EVERY path where the answer they serve costs one resolve, and
	 * `resolveConfig` is the only resolver in the codebase memoised per directory. The roster half
	 * used to be asked from `LintConfig.frameworksFor`, which runs once per framework-aware rule and
	 * re-ran the whole scan each time (its argument is evaluated whatever the once-per-process
	 * ledger later decides) — and for the `RiskyFix` half of those rules, `prefer-inline` under a
	 * configured oracle and `unused-public-member` when enabled, `FixVerifier` installs no resolver
	 * at all, so each scan was an uncached `LintConfig.discover` walk per file. The three `resolveConfig`
	 * sweeps in `runLint` leave the directory cache warm, so here none of them costs anything.
	 *
	 * The first two are GATED on whether this run consults their setting, because each sentence claims
	 * the first root's answer "applies to all N file(s)": `--no-oracle` takes no oracle verdict, and a
	 * run holding no `FrameworkAware` rule (`--rule prefer-single-quotes`, or a config disabling all
	 * four) applies no roster. An ungated line would be the same defect as the silence it replaced,
	 * pointing the other way.
	 *
	 * The third is NOT gated, and that is the same reasoning rather than an exception: the missing project
	 * roots are a property of the resolution scope EVERY check shares, not of one setting one family reads,
	 * and the report half of that scope is what a `--range`-narrowed `--fix` behind a write op runs on. The
	 * gate its two neighbours use is a marker interface (`c is FrameworkAware`), which works because a
	 * framework-aware rule cannot read the roster without declaring itself; nothing similar guards the wide
	 * index — a check reaches it by calling `IndexScope.widestScopeIndex`, so any marker here would be
	 * a hand-kept roster of the five that do, failing open the day a sixth joins them.
	 */
	private static function warnScopeNotices(
		activeChecks: Array<Check>, resolveConfig: (String) -> LintConfig, paths: Array<String>, noOracle: Bool
	): Void {
		if (activeChecks.exists(c -> c is FrameworkAware)) ConfigDisagreement.warnRoster(resolveConfig, paths);
		if (!noOracle) ConfigDisagreement.warnOracle(resolveConfig, paths);
		ConfigDisagreement.warnMissingProjectRoots(resolveConfig, paths);
	}

	/**
	 * Apply each active check's autofix across the file set in `--fix` mode,
	 * iterating to a FIXED POINT. A fix can expose a new finding — deleting a
	 * dead-code run leaves a local unused; de-nesting a `redundant-else`
	 * `else if` chain surfaces the inner `else` — so a single pass is not
	 * enough. Each pass re-lints the in-memory (already-fixed) sources and
	 * re-applies; only files a prior pass changed are revisited (a fix exposes
	 * new findings only in a file it edited). Per file, a pass batches the
	 * fixable edits from every check into ONE `RefactorSupport.canonicalize`
	 * (so several deletions apply end-to-start without span-shift). Sources are
	 * mutated in memory and flushed to disk once at the end. A non-canonical
	 * first-pass file is refused by the canonical gate and skipped with a note;
	 * a later-pass refusal (a writer-idempotency wrinkle on our own output)
	 * just stops that file quietly. The pass count is capped as a runaway guard.
	 * Exit is always success — `--fix` is best-effort.
	 * The UNION of `resolutionRoots` across the configs discovered for `paths` — the library dirs whose sources join the resolution scope.
	 * The deduped union of a per-config string list across every linted path — the
	 * shared shape of the `resolutionRoots` / `resolutionLibs` gathering, differing
	 * only in which `LintConfig` accessor supplies each config's values.
	 */
	private static function unionConfigStrings(
		paths: Array<String>, resolveConfig: (String) -> LintConfig, select: (LintConfig) -> Array<String>
	): Array<String> {
		final out: Array<String> = [];
		for (p in paths) for (s in select(resolveConfig(p))) if (!out.contains(s)) out.push(s);
		return out;
	}

	/**
	 * Read every `.hx` under the project's declared `resolutionRoots`, excluding the run's own report
	 * files (`reportPaths`, keyed by `realPath`) — the PROJECT half of the resolution scope.
	 *
	 * Separable from the library half because of what a write scan may believe. A declared root is the
	 * project's OWN source, so a file there can assign a project type's field; a haxelib and the Haxe
	 * std cannot — the dependency runs the other way. Admitting them to a scan keyed on a member NAME
	 * therefore only ever suppresses: folding the library into `prefer-final-public-field` /
	 * `prefer-read-only-field`'s write index loses every finding whose field name the std also
	 * spells (`speed`, `panel`, `timer`, `ready`, `names`) and gains none.
	 */
	private static function readResolutionRoots(
		roots: Array<String>, reportPaths: Map<String, Bool>
	): { files: Array<{ file: String, source: String }>, matched: Bool, allMatched: Bool } {
		// Expanded per ROOT rather than in one call, so a root that matches nothing can be NAMED.
		// A declared root resolving to no `.hx` — a typo, a directory since moved, a path written
		// against the wrong base — leaves `projectRoots` empty, which is byte-identical to never
		// declaring the key: `RefactorSupport.resolutionProjectSourcesOf` answers null and the
		// cross-file proofs answer from the report scope. `ConfigDisagreement.warnMissingProjectRoots`
		// is blind to it by construction — it reads the config, where the key IS present — so this is
		// the only place that learns it, and it learns it lazily.
		// `seen` grows as roots are read because the per-root expansion cannot dedup across roots the
		// way one call over every spec could: two overlapping roots would otherwise index a shared
		// file TWICE, and duplicate declarations are what trips the resolver's ambiguity gate.
		final out: Array<{ file: String, source: String }> = [];
		final seen: Map<String, Bool> = reportPaths.copy();
		final unreachable: Array<String> = [];
		for (root in roots) {
			final paths: Array<String> = CliArgs.expandInputs([root], '.hx').paths;
			if (paths.length == 0) {
				unreachable.push(root);
				continue;
			}
			for (entry in readExpanded(paths, seen)) {
				seen[FileIdentity.realPath(entry.file)] = true;
				out.push(entry);
			}
		}
		ConfigDisagreement.warnUnreachableProjectRoots(unreachable);
		// MATCHED counts the report files too: a whole-project lint excludes every root file from `out`,
		// and its roots matched all the same.
		return { files: out, matched: unreachable.length < roots.length, allMatched: unreachable.length == 0 };
	}

	/**
	 * Read every `.hx` under the resolution scope's LIBRARY roots — `libNames` resolved to haxelib
	 * source dirs, plus the auto-discovered Haxe std — excluding the run's own report files
	 * (`reportPaths`, keyed by `realPath`) and everything `readResolutionRoots` already read
	 * (`alreadyRead`). Together with that function, the whole of `resolutionThunk`'s FIRST-DEMAND
	 * work, split out so the thunk itself is the memo and nothing else.
	 *
	 * A lib dir or std spec that IS a declared root needs no dir-level dedup here: its files were
	 * already read as roots, so `alreadyRead` drops them one by one — which is what the single
	 * pre-split scan list achieved by seeding itself with `roots`.
	 */
	private static function readResolutionLibrary(
		libNames: Array<String>, stdEnabled: Bool, reportPaths: Map<String, Bool>, alreadyRead: Array<{ file: String, source: String }>
	): { declared: Array<{ file: String, source: String }>, std: Array<{ file: String, source: String }> } {
		// Resolve the declared haxelib NAMES to source dirs ON FIRST DEMAND ONLY — the
		// `haxelib libpath` spawn lives here, reached only through the thunk, never in its
		// null-decision, so a run whose checks never build the index (e.g. `--rule
		// prefer-single-quotes`) pays no haxelib cost. A name that does not resolve (typo /
		// uninstalled) is dropped with a stderr note so the run proceeds as if the lib were absent.
		final scanRoots: Array<String> = [];
		final dirs: Array<Null<String>> = HaxelibResolver.libSourceDirs(libNames);
		for (i => name in libNames) {
			final dir: Null<String> = dirs[i];
			if (dir == null)
				CliIo.stderr('apq lint: resolutionLibs: could not resolve haxelib "$name" (not installed?); skipping\n');
			else if (!scanRoots.contains(dir))
				scanRoots.push(dir);
		}
		// The auto-discovered Haxe std joins the SAME scope as the declared roots / libs
		// (StdResolver — ONE channel, no hardcoded machine-specific paths): its target-agnostic
		// core (toplevel *.hx + haxe/ + sys/) as expandInputs specs, deduped against any explicit
		// std root. Unconditional apart from the explicit opt-out — whether a std type resolves must
		// not depend on the project happening to declare a library, so `resolutionThunk`'s
		// null-decision admits a std-only scope. `stdEnabled` false is the project declining it
		// (`"resolutionStd": false`); a null `stdDir` is no std on the machine, or `APQ_NO_STD`
		// declining it process-wide. Either way the scope stays exactly as declared.
		// `StdResolver.stdDir` memoises, so the `which haxe` probe runs at most once per process
		// whichever side reaches it first.
		// The std is read as a half of its own, after the declared libraries and without what they already hold, so a consumer
		// can ask the project's code apart from the std it calls into (`ResolutionSources.declared`).
		final stdDir: Null<String> = stdEnabled ? StdResolver.stdDir() : null;
		final stdSpecs: Array<String> = stdDir == null ? [] : [
			for (spec in StdResolver.resolutionSpecs(stdDir)) if (!scanRoots.contains(spec)) spec
		];
		final exclude: Map<String, Bool> = reportPaths.copy();
		for (entry in alreadyRead) exclude[FileIdentity.realPath(entry.file)] = true;
		final declared: Array<{ file: String, source: String }> = readResolutionSources(scanRoots, exclude);
		for (entry in declared) exclude[FileIdentity.realPath(entry.file)] = true;
		return { declared: declared, std: stdSpecs.length == 0 ? [] : readResolutionSources(stdSpecs, exclude) };
	}

	/** Read every `.hx` matched by `specs`, skipping any whose `realPath` is in `exclude` and any that cannot be read. */
	private static function readResolutionSources(
		specs: Array<String>, exclude: Map<String, Bool>
	): Array<{ file: String, source: String }> {
		return readExpanded(CliArgs.expandInputs(specs, '.hx').paths, exclude);
	}

	/** Read each of `paths`, skipping any whose `realPath` is in `exclude` and any that cannot be read. */
	private static function readExpanded(paths: Array<String>, exclude: Map<String, Bool>): Array<{ file: String, source: String }> {
		final out: Array<{ file: String, source: String }> = [];
		for (path in paths) if (!exclude.exists(FileIdentity.realPath(path))) {
			final src: Null<String> = try CliIo.readSourceForParse(path) catch (exception: Exception) null;
			if (src != null) out.push({ file: path, source: src });
		}
		return out;
	}

}
