package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.ConfigDisagreement;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.query.Address.TreeAddresser;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.cli.CliContext;
import anyparse.query.format.LintFormat;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * The `lint --fix` check sets, split by how each is applied: `risky` is verified against the compiler oracle, `safe` runs in the unverified fixpoint loop, and `safe` in turn splits into `activeScope` (re-linted only over the files a prior pass changed) and `fullScope` (re-linted over the whole file set every pass).
 */
typedef CheckPartition = {
	var risky: Array<Check>;
	var safe: Array<Check>;
	var activeScope: Array<Check>;
	var fullScope: Array<Check>;
};

/**
 * Parsed options for `apq lint` — `lang`, `flat`, `includeInfo`, `fix`, the `failOn` severity, output `format`, `ruleFilters`, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef LintOpts = {
	var lang: String;
	var flat: Bool;
	var includeInfo: Bool;
	var fix: Bool;
	var noOracle: Bool;
	var failOn: Null<Severity>;
	var format: String;
	var ruleFilters: Array<String>;
	var inputSpecs: Array<String>;
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

	private static inline final FORMAT_JSON: String = 'json';

	private static inline final FORMAT_CHECKSTYLE: String = 'checkstyle';

	private static inline final FORMAT_TEXT: String = 'text';

	public function new() {}

	public function name(): String {
		return 'lint';
	}

	public function summary(): String {
		return 'Run analysis checks and report violations (e.g. unused-import)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runLint(args);
	}

	public function usage(): Void {
		printLintUsage();
	}

	/** Source-offset sort key for a violation span; null spans sort last. */
	private static inline function spanStart(span: Null<Span>): Int {
		return span != null ? span.from : CliArgs.MAX_INT;
	}

	private static inline function lintParseExit(code: Int): LintOpts {
		return {
			lang: '',
			flat: false,
			includeInfo: false,
			fix: false,
			noOracle: false,
			failOn: null,
			format: FORMAT_TEXT,
			ruleFilters: [],
			inputSpecs: [],
			errExit: code
		};
	}

	/**
	 * `apq lint <scope> [--rule <id>]... [--all] [--flat] [--lang <name>]`
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
	 */
	private static function runLint(args: Array<String>): Int {
		final o: LintOpts = parseLintArgs(args);
		if (o.errExit != null) return o.errExit;
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq lint: expected <scope> (one or more file/dir/glob specs)\n');
			printLintUsage();
			return EXIT_USAGE;
		}

		final checks: Null<Array<Check>> = resolveLintChecks(o.ruleFilters);
		if (checks == null) return EXIT_USAGE;

		final io = CliArgs.resolveInputPaths(o.lang, o.inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq lint: ${CliArgs.quotedSpecs(o.inputSpecs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;

		final files: Array<{ file: String, source: String }> = [];
		final sourceOf: Map<String, String> = [];
		for (path in paths) {
			final fileSource: String = try CliIo.readSourceForParse(path) catch (exception: Exception) {
				CliIo.stderr('apq lint: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			files.push({ file: path, source: fileSource });
			sourceOf[path] = fileSource;
		}

		// Per-file config: discover an apqlint.json by walking up from EACH linted
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
		final activeChecks: Array<Check> = applyEnablement ? [
			for (c in checks) if (files.exists(f -> resolveConfig(f.file).enabledFor(c.id(), !(c is DefaultOff)))) c
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
		final resolution: Null<ResolutionScope> = resolutionThunk(
			files, resolutionRoots, resolutionLibs, paths.foreach(p -> resolveConfig(p).resolutionStd())
		);
		// Compiler oracle (opt-in via apqlint.json `compilerOracle`): a project-level
		// setting, so the config resolved for the first linted file carries it for the
		// whole run — its hxml is typechecked as ground truth below. That stays; what it owes
		// the reader is a word when the scope spans roots that name DIFFERENT builds, since
		// every risky and oracle-assisted verdict below is then taken against a build the
		// second root never declared.
		warnScopeDisagreements(activeChecks, resolveConfig, paths, o.noOracle);
		final oracleConfig: Null<LintConfig> = paths.length > 0 ? resolveConfig(paths[0]) : null;
		final oracleHxml: Null<String> = oracleConfig?.compilerOracle();
		final oracleDir: Null<String> = oracleConfig?.compilerOracleDir();

		if (o.fix)
			return LintFixDriver.runLintFix(
				files, activeChecks, plugin, resolveConfig, applyEnablement, resolution, oracleHxml, oracleDir, o.noOracle
			);

		// Report mode only — the fix path returned above, so this pass never runs redundantly in a
		// --fix run. The resolution scope joins the checks' SymbolIndex; findings stay in the report
		// files. ONE wrapper serves both halves of the pass: the address annotation in the report
		// reads the trees the checks just parsed out of its cache instead of parsing them again.
		final cached: CachingGrammarPlugin = wrapResolution(plugin, resolution);
		final all: Array<Violation> = Linter.run(files, cached, activeChecks, resolveConfig, applyEnablement);

		final shown: Array<Violation> = reportedViolations(all, o.includeInfo, o.format);
		renderLintReport(paths, shown, sourceOf, o.format, o.flat, cached);
		lintSummary(all, paths, shown.length == all.length, LintFixVerify.unparseableFiles(files, cached));

		// `--no-oracle` skips the typecheck entirely rather than faking its verdict:
		// the note below says the compiler was not asked, so nothing downstream can
		// read an unproved run as a proved one. It exists because the oracle is a
		// PROJECT-WIDE typecheck regardless of how narrow the lint scope is — 16.1s of
		// an 18.7s single-file run, which is the inner loop's largest single tax.
		final oracleExit: Null<Int> = o.noOracle
			? LintFixVerify.oracleSkippedNote(oracleHxml)
			: LintFixVerify.reportModeOracle(oracleHxml, oracleDir, paths, oracleConfig?.compilerOracleServer() ?? false);
		if (oracleExit != null) return oracleExit;

		final failOn: Null<Severity> = o.failOn;
		if (failOn != null) {
			final threshold: Int = (cast failOn: Int);
			for (v in all) if ((cast v.severity: Int) <= threshold) return EXIT_RUNTIME;
		}
		return EXIT_OK;
	}

	/**
	 * The two scope-level `apqlint.json` diagnostics, once per run, from the one place that can
	 * afford them and can tell whether the run consults each setting.
	 *
	 * Both ask their question of EVERY path where the answer they serve costs one resolve, and
	 * `resolveConfig` is the only resolver in the codebase memoised per directory. The roster half
	 * used to be asked from `LintConfig.frameworksFor`, which runs once per framework-aware rule and
	 * re-ran the whole scan each time (its argument is evaluated whatever the once-per-process
	 * ledger later decides) — and for the `RiskyFix` half of those rules, `prefer-inline` under a
	 * configured oracle and `unused-public-member` when enabled, `FixVerifier` installs no resolver
	 * at all, so each scan was an uncached `LintConfig.discover` walk per file. The three
	 * `resolveConfig` sweeps in `runLint` leave the directory cache warm, so here both cost nothing.
	 *
	 * Each is GATED on whether this run consults its setting, because the sentence claims the first
	 * root's answer "applies to all N file(s)": `--no-oracle` takes no oracle verdict, and a run
	 * holding no `FrameworkAware` rule (`--rule prefer-single-quotes`, or a config disabling all
	 * four) applies no roster. An ungated line would be the same defect as the silence it replaced,
	 * pointing the other way.
	 */
	private static function warnScopeDisagreements(
		activeChecks: Array<Check>, resolveConfig: (String) -> LintConfig, paths: Array<String>, noOracle: Bool
	): Void {
		if (activeChecks.exists(c -> c is FrameworkAware)) ConfigDisagreement.warnRoster(resolveConfig, paths);
		if (!noOracle) ConfigDisagreement.warnOracle(resolveConfig, paths);
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
	 * false (an `apqlint.json` `"resolutionStd": false`) or `StdResolver.stdDir()` finds none (no Haxe
	 * on the machine, or `APQ_NO_STD` declining it). The short-circuit order matters: with either key
	 * declared, `StdResolver.stdDir()` is never reached, so those projects stay byte-identical. A
	 * project declaring NEITHER key pays one memoised `which haxe` probe (`StdResolver.stdDir` computes
	 * once per process) — so its inertness guarantee is "spawns no haxelib; one `which haxe` at most",
	 * not "spawns nothing".
	 *
	 * Reading the `files` array live keeps the report portion current across `--fix` passes; the
	 * library portion is immutable.
	 */
	private static function resolutionThunk(
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
		// and the whole dedup misses. `realPath` resolves the link.
		// A MAP, not an array: the library always carries the ~200 std files, so a linear `contains`
		// over the report would be one string compare per (report x library) pair — ~160k on an
		// 800-file project, for a lookup that is answered in one hash.
		final reportPaths: Map<String, Bool> = [for (f in files) realPath(f.file) => true];
		var library: Null<Array<{ file: String, source: String }>> = null;
		return {
			declared: declared,
			sources: () -> {
				final memoised: Null<Array<{ file: String, source: String }>> = library;
				final libFiles: Array<{ file: String, source: String }> = memoised ?? readResolutionLibrary(
					roots, libNames, stdEnabled, reportPaths
				);
				library = libFiles;
				return { report: files, library: new LibrarySources(libFiles) };
			}
		};
	}

	/**
	 * `path` as the one string that names its file however the path was spelled — absolute, and with
	 * every symlink on the way resolved.
	 *
	 * The identity the resolution-scope dedup compares by. `absolutePath` only prefixes the CWD, so
	 * two spellings that traverse a symlink differently stay two strings for one file, which is a
	 * dedup that misses in silence.
	 *
	 * Never null and never empty, whatever `path` was — see the body for why that is not what the
	 * declared type of the call inside it promises.
	 */
	public static function realPath(path: String): String {
		// `FileSystem.fullPath` is DECLARED to return a non-null `String` and on hxnodejs RETURNS NULL
		// for a path that does not exist — it does not throw, so a bare try/catch never sees it and
		// `@:nullSafety` trusts the declaration (measured on Haxe 4.3.7 / hxnodejs; the same fact is
		// recorded at `OracleCoverage.hx`). Unbridged, a path that fails to resolve keys this map under
		// the string "null", and two such paths — one report, one library — collapse onto ONE key, which
		// silently drops a library file. The catch stays for the targets where it DOES throw.
		//
		// NOT also guarded against `''`, unlike `OracleCoverage.canonical`: probed on node,
		// `fs.realpathSync('')` and `path.resolve('')` both answer the cwd, so neither branch can
		// produce one, and a guard no input can reach is a claim about behaviour nobody measured.
		// Mutations: dropping the null bridge fails 1 test, replacing the body with `absolutePath` 2.
		final full: Null<String> = try FileSystem.fullPath(path) catch (exception: Exception) null;
		return full ?? FileSystem.absolutePath(path);
	}

	/**
	 * Read every `.hx` under the resolution scope's roots — `roots` verbatim, `libNames` resolved
	 * to haxelib source dirs, plus the auto-discovered Haxe std — excluding the run's own report
	 * files (`reportPaths`, keyed by `realPath`). The whole of `resolutionThunk`'s FIRST-DEMAND work,
	 * split out so the thunk itself is the memo and nothing else.
	 */
	private static function readResolutionLibrary(
		roots: Array<String>, libNames: Array<String>, stdEnabled: Bool, reportPaths: Map<String, Bool>
	): Array<{ file: String, source: String }> {
		// Resolve the declared haxelib NAMES to source dirs ON FIRST DEMAND ONLY — the
		// `haxelib libpath` spawn lives here, reached only through the thunk, never in its
		// null-decision, so a run whose checks never build the index (e.g. `--rule
		// prefer-single-quotes`) pays no haxelib cost. A name that does not resolve (typo /
		// uninstalled) is dropped with a stderr note so the run proceeds as if the lib were absent.
		final scanRoots: Array<String> = roots.copy();
		for (name in libNames) {
			final dir: Null<String> = HaxelibResolver.libSourceDir(name);
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
		final stdDir: Null<String> = stdEnabled ? StdResolver.stdDir() : null;
		if (stdDir != null) for (spec in StdResolver.resolutionSpecs(stdDir)) if (!scanRoots.contains(spec)) scanRoots.push(spec);
		final libFiles: Array<{ file: String, source: String }> = [];
		for (path in CliArgs.expandInputs(scanRoots, '.hx').paths) if (!reportPaths.exists(realPath(path))) {
			final src: Null<String> = try CliIo.readSourceForParse(path) catch (exception: Exception) null;
			if (src != null) libFiles.push({ file: path, source: src });
		}
		return libFiles;
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
	 * Split `checks` into the sets `lint --fix` applies differently.
	 *
	 * A RiskyFix check is verified against the compiler oracle and is EXCLUDED from the
	 * unverified safe loop. The `OracleRelaxable` checks (prefer-inline, prefer-interpolation)
	 * are the exception: each has a byte-identical safe subset, so WITHOUT an oracle it runs in
	 * the safe loop (null-safety gate on) instead of being left report-only, and WITH an oracle
	 * it joins the verified risky set with its candidate set widened (`setOracleRelaxed`,
	 * applied by the caller). Every OTHER RiskyFix check (avoid-dynamic) keeps the contract: verified when an
	 * oracle is configured, report-only via `verifyRiskyFixes` otherwise — its risky fix is
	 * NEVER applied unverified. So a RiskyFix check only leaves the risky set for the safe loop
	 * when it is OracleRelaxable AND no oracle is configured.
	 *
	 * The safe set then splits by lint SCOPE: a per-file check decides a file's findings from
	 * that file alone, so later passes re-lint only the files a prior pass changed. A cross-file
	 * check must see every file or it mis-resolves on the active subset — those run over the
	 * full set each pass.
	 */
	public static function partitionChecks(checks: Array<Check>, oracleConfigured: Bool): CheckPartition {
		final relaxableNoOracle: (Check) -> Bool = c -> !oracleConfigured && c is OracleRelaxable;
		final safeChecks: Array<Check> = [for (c in checks) if (!(c is RiskyFix) || relaxableNoOracle(c)) c];
		final fullScopeIds: Array<String> = [
			'unused-private',
			'prefer-final-field',
			'unused-parameter',
			'prefer-final-public-field',
			'prefer-read-only-field',
			'field-init-at-declaration',
			// Resolves a path receiver's member types through a SymbolIndex over the set it is
			// given — on the active SUBSET a type declared elsewhere reads as unresolvable, which
			// re-flags the very loops the type gate is meant to skip.
			'map-keys-lookup',
			// Same cross-file path-receiver resolution as map-keys-lookup: on the active SUBSET a
			// declaring type reads as unresolvable and a Map get/set finding re-exposed by an earlier
			// pass (a nested lookup) is re-skipped, so the fixed-point loop never converges on it.
			'prefer-index-access',
			// Its no-null-value census enumerates every occurrence of the map's name across the
			// scope it is given. On the active SUBSET a writer in an untouched file is invisible,
			// which would turn an unprovable site into a wrongly PROVEN one — the unsound
			// direction, unlike the misses the other ids here guard against.
			'redundant-map-exists',
			// prefer-static-extension's shadow gate resolves the receiver type — and its whole
			// supertype / alias closure — through the index. On the active SUBSET a declaring type
			// or a `typedef` target declared elsewhere reads as unresolvable, so a site an earlier
			// pass exposed degrades to report-only and the loop never converges on it.
			'prefer-static-extension',
			// redundant-tostring's fix gates resolve the receiver's TYPE through the index — is it
			// declared, extern, a class. On the active SUBSET a type declared elsewhere reads as
			// unresolvable, so a site an earlier pass exposed degrades to report-only and the loop
			// never converges on it; worse, run() and fix() would then disagree, since
			// computeFileLintEdits hands fix() the whole-report index either way.
			'redundant-tostring',
			// prefer-inline's soundness gates are ALL whole-project: the subtype-override gate
			// (SymbolIndex.hasSubtype + a strict-subtype member lookup), the value-reference name scan, and
			// the interface gate. On the active SUBSET a subtype / value-use / interface declared elsewhere
			// reads as absent, so an overridden or value-referenced method is wrongly inlined ("Field X is
			// inlined and cannot be overridden").
			'prefer-inline',
			// trivial-getter's collapse gates are whole-project too: subtypeBlocks /
			// subtypeFieldBlocks resolve the owner's subtypes through the index. On the
			// active SUBSET a subtype declared elsewhere reads as absent, so a later
			// pass can collapse a property whose backing field a subtype still uses.
			'trivial-getter',
			// naming's cross-file field rename (crossFileFix) resolves an owner's subtype /
			// @:access-grant files through the whole-project index; on the active SUBSET a subtype
			// declared elsewhere reads as absent. Full-scope also re-reports the declaring file's
			// violation every pass, so a rename deferred by a same-file conflict re-fires until it lands.
			'naming',
			// prefer-typed-throw's verdict is whole-scope: a `catch (e:String)` ANYWHERE degrades the
			// rule to report-only. When no resolution scope exists the gate falls back to the file set
			// it is handed, so on the active SUBSET a catch declared elsewhere reads as absent and a
			// throw a first pass correctly refused would be boxed by a later one.
			'prefer-typed-throw',
			// orphan-accessor's every deletion gate is whole-project: the property is resolved through
			// the supertype chain, and the zero-direct-call proof scans every file in report scope. On
			// the active SUBSET a supertype declared elsewhere reads as unresolvable and a call site in
			// an unchanged file reads as absent — the first would silence a real finding, the second
			// would delete a method something still calls.
			'orphan-accessor',
			// unused-public-member's every gate is whole-project: the supertype chain resolution
			// and the reference scan over the whole token map. On the active SUBSET a call site
			// in an unchanged file reads as absent, so `--fix` would delete a method the rest of
			// the project still calls. Its DELETIONS reach the tree through the RiskyFix verifier
			// (which runs the whole set too) rather than this loop. `fullScopeIds` is read ONLY to
			// partition `safeChecks`, which a RiskyFix check never joins (it is not
			// `OracleRelaxable`), so the entry is INERT today — it is kept because it would carry
			// the fixes again if the rule ever stopped being risky.
			'unused-public-member',
			// inline-constant's reflection gate is the same whole-project string scan its three
			// siblings on this list share (`orphan-accessor` and `unused-public-member` above,
			// `static-constant` below), and it gates the FINDING rather than the fix. On the
			// active SUBSET a `Reflect.field(o, "NAME")` in an unchanged file reads as absent, so a
			// constant pass 1 correctly refused is marked `inline` by pass 2 — measured on a
			// two-file fixture where the whole-set REPORT named one finding and the same command's
			// `--fix` reported `fixed 2 issue(s) over 3 pass(es)`.
			'inline-constant',
			// static-constant's reachability gates are all whole-project: the subtype MENTION gate
			// (a subtype's unqualified read of a private static does not resolve) and the
			// reflection-name scan over every string literal in scope. On the active SUBSET a
			// subtype or a `Reflect.field(o, "NAME")` in an unchanged file reads as absent, so a
			// later pass would promote a field whose read then fails to compile.
			'static-constant'
		];
		return {
			risky: [for (c in checks) if (c is RiskyFix && !relaxableNoOracle(c)) c],
			safe: safeChecks,
			activeScope: [for (c in safeChecks) if (!fullScopeIds.contains(c.id())) c],
			fullScope: [for (c in safeChecks) if (fullScopeIds.contains(c.id())) c]
		};
	}

	private static function printLintUsage(): Void {
		CliIo.sysPrint('Usage: apq lint <scope...> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Run the analysis checks over the scope (one or more file/dir/glob specs) and\n');
		CliIo.sysPrint('report violations grouped by file as <line>:<col>: [severity] message (rule).\n');
		CliIo.sysPrint('Info advisories are hidden from the TEXT report unless --all; json and\n');
		CliIo.sysPrint('checkstyle always carry every finding, since their stdout is the answer a\n');
		CliIo.sysPrint('machine consumer gets. The exit code is success unless\n');
		CliIo.sysPrint('--fail-on selects a severity present in the findings. Run --list-rules for\n');
		CliIo.sysPrint('the full check list (id + description, one per line).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Inline suppression: a trailing "// noqa" (or "// noqa: <rule>,<rule>") clears\n');
		CliIo.sysPrint('findings on its line; "// CHECKSTYLE:OFF" ... "// CHECKSTYLE:ON" clears a region.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Project config: an "apqlint.json" discovered by walking up from a linted file\n');
		CliIo.sysPrint('enables/disables rules and overrides their severity or options, e.g.\n');
		CliIo.sysPrint('{ "rules": { "naming": { "severity": "error" }, "complexity": { "max": 15 },\n');
		CliIo.sysPrint('"fold-adjacent-string-literals": { "enabled": false } } }.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A top-level "compilerOracle" key (path to an .hxml, relative to the config)\n');
		CliIo.sysPrint('runs "haxe <hxml> --no-output" as a ground-truth typecheck: a compile error\n');
		CliIo.sysPrint('fails the run, a RiskyFix rule fix is reverted under --fix if it breaks the\n');
		CliIo.sysPrint('build, and an OracleAssisted rule (explicit-local-type, explicit-type) asks a\n');
		CliIo.sysPrint('warm display server for the type of each finding it cannot resolve structurally,\n');
		CliIo.sysPrint('reverting any annotated file that fails to typecheck. Without the key no\n');
		CliIo.sysPrint('compiler is ever spawned.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --rule <id>       Run only this check (repeatable; default: all)\n');
		CliIo.sysPrint('  --list-rules      List every registered check and exit\n');
		CliIo.sysPrint('  --fix            Apply autofixes in place (e.g. delete unused imports)\n');
		CliIo.sysPrint('  --fail-on <sev>   Exit non-zero if a finding at-or-above <sev> exists\n');
		CliIo.sysPrint('                    (error|warning|info)\n');
		CliIo.sysPrint('  --no-oracle       Skip the compiler-oracle typecheck (a PROJECT-WIDE build\n');
		CliIo.sysPrint('                    regardless of scope: 16s of an 18.7s single-file run).\n');
		CliIo.sysPrint('                    Report mode: findings are unchanged, the run just cannot\n');
		CliIo.sysPrint('                    claim compiler-confirmed nullSafety trust. With --fix it\n');
		CliIo.sysPrint('                    ALSO turns off every oracle-backed net, as if no\n');
		CliIo.sysPrint('                    compilerOracle were configured: a fix that breaks the build\n');
		CliIo.sysPrint('                    is NOT reverted, RiskyFix rules stay report-only and\n');
		CliIo.sysPrint('                    OracleAssisted rules are inert. Use it in an iteration loop\n');
		CliIo.sysPrint('                    (the only way to see the fixer raw), NEVER in a gate\n');
		CliIo.sysPrint('  --format <fmt>    Output format: text (default), json, checkstyle\n');
		CliIo.sysPrint('  --all, -a        Include Info-severity advisories in the report (text format only —\n');
		CliIo.sysPrint('                   json and checkstyle are never capped)\n');
		CliIo.sysPrint('  --flat           One <file>:<line>:<col> per line (text format only)\n');
		CliIo.sysPrint('  --lang <name>    Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help       Show this help\n');
	}

	private static function parseLintArgs(args: Array<String>): LintOpts {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var includeInfo: Bool = false;
		var fix: Bool = false;
		var noOracle: Bool = false;
		var failOn: Null<Severity> = null;
		var format: String = FORMAT_TEXT;
		final ruleFilters: Array<String> = [];
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--rule':
					ruleFilters.push(CliArgs.expectValue(args, ++i, '--rule'));
				case '--all', '-a':
					includeInfo = true;
				case '--flat':
					flat = true;
				case '--fix':
					fix = true;
				case '--no-oracle':
					noOracle = true;
				case '--fail-on':
					final level: String = CliArgs.expectValue(args, ++i, '--fail-on');
					failOn = Severity.fromName(level);
					if (failOn == null) {
						CliIo.stderr('apq lint: unknown --fail-on value "$level" (expected error|warning|info)\n');
						return lintParseExit(EXIT_USAGE);
					}
				case '--format':
					format = CliArgs.expectValue(args, ++i, '--format');
					if (format != FORMAT_TEXT && format != FORMAT_JSON && format != FORMAT_CHECKSTYLE) {
						CliIo.stderr('apq lint: unknown --format value "$format" (expected text|json|checkstyle)\n');
						return lintParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printLintUsage();
					return lintParseExit(EXIT_OK);
				case '--list-rules':
					printLintRules();
					return lintParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq lint: unknown option "$a"\n');
						return lintParseExit(EXIT_USAGE);
					}
					inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			flat: flat,
			includeInfo: includeInfo,
			fix: fix,
			noOracle: noOracle,
			failOn: failOn,
			format: format,
			ruleFilters: ruleFilters,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function resolveLintChecks(ruleFilters: Array<String>): Null<Array<Check>> {
		final checks: Array<Check> = [];
		if (ruleFilters.length == 0) {
			for (check in Linter.builtins()) checks.push(check);
		} else {
			for (id in ruleFilters) {
				final check: Null<Check> = Linter.byId(id);
				if (check == null) {
					CliIo.stderr('apq lint: unknown rule "$id"\n');
					return null;
				}
				checks.push(check);
			}
		}
		return checks;
	}

	/**
	 * The findings the REPORT carries, out of everything the run produced.
	 *
	 * `--all` off hides `Info` advisories — a READABILITY affordance for the text report, where a
	 * terminal reader gets the errors and warnings and is TOLD on stderr what was withheld. A machine
	 * format has no such reader: its stdout IS the answer, and a consumer redirecting it keeps nothing
	 * of the stderr note. Capping there returned a truncated record set with nothing in band to say
	 * so — `[]` for a run holding findings, while `--fail-on info` (which counts every finding, capped
	 * or not) exits 1 on that same run. The payload and the exit code disagreed, and the payload was
	 * the one that was wrong; `--all` now governs the human report alone.
	 */
	public static function reportedViolations(all: Array<Violation>, includeInfo: Bool, format: String): Array<Violation> {
		return includeInfo || format == FORMAT_JSON || format == FORMAT_CHECKSTYLE ? all : all.filter(v -> v.severity != Severity.Info);
	}

	private static function renderLintReport(
		paths: Array<String>, shown: Array<Violation>, sourceOf: Map<String, String>, format: String, flat: Bool,
		plugin: CachingGrammarPlugin
	): Void {
		// Group findings per file, each group sorted by source position so the report
		// reads top-to-bottom. ONE pass rather than a filter per path: that scan was
		// O(paths x findings) and the text branch below ran a second one. `paths` is
		// deduplicated and order-preserving (`expandInputs`), and a file's findings enter
		// a group in `shown` order exactly as the filter yielded them, so every format's
		// emitted sequence is unchanged.
		final byFile: Map<String, Array<Violation>> = [];
		for (v in shown) {
			final group: Null<Array<Violation>> = byFile[v.file];
			if (group == null)
				byFile[v.file] = [v];
			else
				group.push(v);
		}
		for (group in byFile) group.sort((a, b) -> spanStart(a.span) - spanStart(b.span));
		// The two record formats want the groups concatenated in input-file order; the text
		// branch prints them one group at a time and needs no such array.
		inline function orderedByPath(): Array<Violation> {
			final flatten: Array<Violation> = [];
			for (path in paths) {
				final group: Null<Array<Violation>> = byFile[path];
				if (group != null) for (v in group) flatten.push(v);
			}
			return flatten;
		}

		switch format {
			case FORMAT_JSON:
				// Each record carries the finding's canonical edit-stable selector
				// (`address`) — directly usable as a mutation-op --select argument.
				// The plugin is the one the CHECKS just ran through, so its parse cache
				// already holds every reported file; a fresh wrapper here would parse each
				// of them a second time, which dominated the whole annotation.
				final ordered: Array<Violation> = orderedByPath();
				// Addressing a node probes its tree several times, so an index per FINDING
				// makes the annotation cost far more than the analysis it annotates.
				// `ordered` groups a file's findings together, so the addresser's ONE slot
				// serves a whole file and retains nothing past it — it is a local of this
				// call, which is the run-scoped place for the memo. The slot keys on the
				// TREE, not the path: the parse cache is keyed by CONTENT, and an index
				// handed a node it never saw degrades every address to `<line>:<col>` in
				// silence.
				final addresser: TreeAddresser = new TreeAddresser(plugin.selectKindEquivalence());
				CliIo.sysPrint(LintFormat.json(ordered, sourceOf, v -> {
					final span: Null<Span> = v.span;
					final source: Null<String> = sourceOf[v.file];
					if (span == null || source == null) return null;
					final tree: Null<QueryNode> =
						try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
					return tree == null ? null : addresser.addressAt(tree, source, span.from);
				}));
			case FORMAT_CHECKSTYLE:
				CliIo.sysPrint(LintFormat.checkstyle(orderedByPath(), sourceOf));
			case _:
				for (path in paths) {
					final group: Null<Array<Violation>> = byFile[path];
					if (group != null) CliIo.sysPrint(Text.renderViolations(path, sourceOf[path] ?? '', group, flat));
				}
		}
	}

	/**
	 * The stderr breakdown under a lint report: the files the grammar could not read, the severity
	 * counts, and — when the report was CAPPED — how much it withheld.
	 *
	 * `reportedAll` is what the report actually carried, not the `--all` flag: a machine format is
	 * never capped, so telling its reader that advisories were hidden would be a lie the run has no
	 * way to make true.
	 */
	private static function lintSummary(all: Array<Violation>, paths: Array<String>, reportedAll: Bool, ?skipped: Array<String>): Void {
		// A file the grammar cannot read is a hole in the analysis, and one that stays SILENT
		// otherwise: the per-member confinement gates decline for anything such a file mentions,
		// and nothing in the report says so. Naming the files is what lets a reader tell "no
		// findings" from "could not look".
		if (skipped != null && skipped.length > 0) {
			CliIo.stderr('apq lint: ${skipped.length} file(s) could not be parsed and are invisible to cross-file proofs:\n');
			for (path in skipped.slice(0, CliWalk.SKIP_PATHS_SHOWN)) CliIo.stderr('  $path\n');
			if (skipped.length > CliWalk.SKIP_PATHS_SHOWN) CliIo.stderr('  ... +${skipped.length - CliWalk.SKIP_PATHS_SHOWN} more\n');
		}
		var errors: Int = 0;
		var warnings: Int = 0;
		var infos: Int = 0;
		for (v in all) switch v.severity {
			case Severity.Error:
				errors++;
			case Severity.Warning:
				warnings++;
			case Severity.Info:
				infos++;
		}
		if (all.length == 0) {
			CliIo.stderr('apq lint: no issues in ${paths.length} file(s)\n');
		} else {
			CliIo.stderr('apq lint: $errors error(s), $warnings warning(s), $infos info(s) in ${paths.length} file(s)\n');
			if (!reportedAll && infos > 0) CliIo.stderr('apq lint: $infos info advisory(ies) hidden — pass --all to show\n');
		}
	}

	/**
	 * Print every registered check as `id  description`, one per line, in
	 * registration order — the machine-consumable counterpart of the usage
	 * text (review tooling subtracts linter-owned rules from manual checklists
	 * by this list).
	 */
	private static function printLintRules(): Void {
		final checks: Array<Check> = Linter.builtins();
		var width: Int = 0;
		for (c in checks) if (c.id().length > width) width = c.id().length;
		// The minimum language version a rule's FIX needs is printed with the rule, not
		// discovered after a run that silently dropped it: a project whose `languageVersion`
		// is below it never sees the finding, and this is where that becomes visible.
		for (c in checks) {
			final requires: String = c is VersionGated ? ' [needs ${(cast c: VersionGated).minLanguageVersion()}]' : '';
			CliIo.sysPrint('${c.id().rpad(' ', width)}  ${c.description()}$requires\n');
		}
	}

}
