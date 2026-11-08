package anyparse.query.cli.command;

import anyparse.check.LintConfig;
import anyparse.check.facts.TypedFactsProbe;
import anyparse.check.oracle.ReachBuildsCache;
import anyparse.check.oracle.ReachDefinesProbe;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.OracleProvider;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.cli.command.LintCommand.LintOpts;

using Lambda;

/**
 * The one answer to "how does an `apq lint` run drive its compiler-oracle compiles": the configurations a run declares,
 * the facts and builds compiles started ahead or on demand, the bounds the project declares on computed names, and the
 * end of every compile on every way out.
 */
@:nullSafety(Strict)
final class LintOracleRun {

	/** The config key declaring the classes a class value made from an unreadable name may be of. */
	public static inline final REFLECTIVE_CLASSES: String = 'reflectiveClasses';

	/** The config key declaring the classes a read by an unreadable name may obtain a method of. */
	public static inline final REFLECTIVE_METHOD_HOLDERS: String = 'reflectiveMethodHolders';

	/**
	 * Whether a run starts its compiler-facts compiles before its first pass rather than when a check first asks: only a
	 * `--fix` run (`fix`) that could be asked at all (a resolution scope, `oracles` configurations, no `--no-oracle`) and
	 * is given every rule (`narrowed` is a `--rule` filter). The facts are asked for by the gates of the fixes, so such a
	 * run nearly always asks and then the compiles overlap the checks; a report or a narrowed run keeps asking on demand,
	 * where an early start would compile every configuration for nothing.
	 */
	public static inline function startsFactsEarly(scoped: Bool, oracles: Int, noOracle: Bool, narrowed: Bool, fix: Bool): Bool {
		return fix && scoped && oracles > 0 && !noOracle && !narrowed;
	}

	/**
	 * Every compiler-oracle configuration `config` declares, made ready to use (`OracleGeneration.prepare`:
	 * every stale `generate` entry regenerated, a failed one marked unavailable, each command that ran
	 * named on stderr), or none when this run resolved no config at all (an empty scope).
	 *
	 * Under `--no-oracle` nothing is generated: the run compiles nothing, so it owes no hxml.
	 *
	 * The configurations carry this run's `OracleRunMemo`, so a compile of a tree the run already compiled is answered
	 * from it; `persisted` says the run is a report, which answers its verdict from `OracleCache` when it can.
	 */
	public static function oraclesOf(
		config: Null<LintConfig>, noOracle: Bool, persisted: Bool, files: Array<{ file: String, source: String }>, grammar: GrammarPlugin
	): Array<OracleConfig> {
		final declared: Array<OracleConfig> = config == null ? [] : config.compilerOracles();
		if (noOracle) return declared;
		final compiler: OracleProvider = OracleProviders.of(grammar);
		final prepared: PreparedOracles = compiler.prepareBuilds(declared);
		for (note in prepared.notes) CliIo.stderr('apq lint: compilerOracle $note\n');
		// `files` is the run's own list, which a created file joins: the memo hashes whatever it holds at each question
		// the run's grammar reads the compilers' sources, so each facts compile carries the baseline and the builds' probe
		return compiler.attachRun(prepared.oracles, persisted, () -> files.map(f -> f.file), grammar);
	}

	/**
	 * `resolution` carrying the builds the configured compiler oracles describe (`ReachDefinesProbe`), probed once per run: on
	 * first demand, or from compiles `buildsAhead` started when a question was about to wait on the facts anyway
	 * (`MemberReach.forRun`) — read only if no write came first (`buildsSettled`), so the tree they read is the one an
	 * on-demand probe would have read — only when the project declares the oracle list complete (`reachConfigurationsComplete`):
	 * a `MemberReach` answer may then hold under their conditional compilation and read exactly the code they compile.
	 * An oracle list not declared complete vouches for nothing, since a build it leaves out may compile code no listed
	 * one does. The builds probed are stored under the fingerprint of the input they read (`ReachBuildsCache`), which
	 * a run under `--no-oracle` — compiling nothing — reads instead (`withStoredBuilds`). A run whose paths name different
	 * lists reads no builds, and when one of them `declared` its list complete still carries the hold (`buildsHeld`).
	 * Unchanged with no oracle.
	 */
	public static function withReachConfigurations(
		resolution: Null<ResolutionScope>, oracles: Array<OracleConfig>, noOracle: Bool, complete: Bool, ahead: AheadBuilds,
		?reflective: Array<String>, ?holders: Array<String>, declared: Bool = false
	): Null<ResolutionScope> {
		if (resolution == null || oracles.length == 0) return resolution;
		// a path declared its list complete, so no proof may fall back on what a run with no declared list would read
		if (!complete) return declared ? {
			declared: resolution.declared,
			sources: resolution.sources,
			buildsHeld: heldNote('the linted paths name different compilerOracle lists, so the run reads none as complete')
		} : resolution;
		if (noOracle) return withStoredBuilds(resolution, oracles, reflective, holders);
		var probed: Bool = false;
		var builds: Null<ReachBuilds> = null;
		// the fingerprint of the input the compiles started ahead read, taken before they started
		var aheadKey: Null<ReachBuildsKey> = null;
		// once the run writes, the builds are compiled on demand, as they read the tree then: none starts ahead of a write
		var writing: Bool = false;
		function probe(): Null<ReachBuilds> {
			if (!probed) {
				probed = true;
				final pending: Null<DefinesProbe> = ahead.probe;
				ahead.probe = null;
				// the facts compiles carry the builds' probe: their read files the builds, which the probe then holds
				final facts: Null<() -> Void> = ahead.facts;
				if (pending == null && facts != null) facts();
				final key: Null<ReachBuildsKey> = pending == null ? ReachBuildsCache.fingerprint(oracles) : aheadKey;
				final found: Null<ReachBuilds> = pending == null ? ReachDefinesProbe.probeAll(oracles) : ReachDefinesProbe.finish(pending);
				ReachBuildsCache.store(oracles, key, found);
				builds = bounded(found, reflective, holders);
			}
			return builds;
		}
		function start(): Void {
			if (probed || writing || ahead.probe != null || ahead.facts != null) return;
			aheadKey = ReachBuildsCache.fingerprint(oracles);
			ahead.probe = ReachDefinesProbe.start(oracles);
		}
		function settled(): Void {
			writing = true;
			dropAhead(ahead);
		}
		return {
			declared: resolution.declared,
			sources: resolution.sources,
			builds: probe,
			buildsAhead: start,
			buildsSettled: settled,
			buildsHeld: heldNote('no build this run compiled said which files it parses')
		};
	}

	/**
	 * Start the builds' probe compiles (`ResolutionScope.buildsAhead`) when a check first waits on the facts, in a run that
	 * started the facts compiles early (`factsEarly`, `startsFactsEarly`). Such a run nearly always asks a reach question, and
	 * its first one escalates to the builds (`MemberReach.escalation`): started only when that question came, mid-way through
	 * the first pass, the probes were waited on alone. Started with the facts at the run's start instead, they took
	 * the cores the first pass and the facts needed and bought nothing; started here they compile while the run waits anyway.
	 * A write before the question still drops them unread (`buildsSettled`).
	 */
	public static function startBuildsWithFacts(factsEarly: Bool, resolution: Null<ResolutionScope>): Void {
		final start: Null<() -> Void> = resolution?.buildsAhead;
		if (factsEarly && start != null) start();
	}

	/** The facts compiles a run starts before its first pass (`startsFactsEarly`), or null for a run that asks on demand. */
	public static function earlyFacts(scoped: Bool, oracles: Array<OracleConfig>, o: LintOpts): Null<FactsProbe> {
		return startsFactsEarly(scoped, oracles.length, o.noOracle, o.ruleFilters.length > 0, o.fix)
			? TypedFactsProbe.start(oracles)
			: null;
	}

	/**
	 * `body`'s answer, with the run's compiles ended (`endCompiles`) on every way out, a throw included: an early facts
	 * batch must not run on after a failed run.
	 */
	public static function endingCompiles(
		compiler: OracleProvider, early: Null<FactsProbe>, ahead: AheadBuilds, oracles: Array<OracleConfig>, body: () -> Int
	): Int {
		final answer: Int = try {
			body();
		} catch (exception: Exception) {
			endCompiles(compiler, early, ahead, oracles);
			throw exception;
		};
		endCompiles(compiler, early, ahead, oracles);
		return answer;
	}

	/**
	 * Every compile of the run is done: end the facts compiles no check asked for (`early`), then release the builds, so
	 * another run may regenerate them.
	 */
	public static function endCompiles(
		compiler: OracleProvider, early: Null<FactsProbe>, ahead: AheadBuilds, oracles: Array<OracleConfig>
	): Void {
		if (early != null) TypedFactsProbe.abandon(early);
		compiler.stopServers(oracles);
		dropAhead(ahead);
		compiler.releaseBuilds(oracles);
	}

	/**
	 * `resolution` carrying what the configured compiler oracles typed (`TypedFactsProbe`), compiled once per
	 * run — from `early` when the caller started the compiles ahead, else on first demand — and read on first
	 * demand, each configuration that contributed nothing named on stderr. Unlike the builds it needs no complete
	 * oracle list: code no configuration compiled simply has no facts. A file the run rewrites is dropped from the table
	 * (`factsEdited`). Unchanged with no oracle, or under `--no-oracle`.
	 */
	public static function withCompilerFacts(
		compiler: OracleProvider, resolution: Null<ResolutionScope>, oracles: Array<OracleConfig>, early: Null<FactsProbe>,
		reflective: Null<Array<String>>, holders: Null<Array<String>>, ahead: AheadBuilds, o: LintOpts
	): Null<ResolutionScope> {
		if (resolution == null || oracles.length == 0 || o.noOracle) return resolution;
		var probed: Bool = false;
		var facts: Null<CompilerFacts> = null;
		final edited: Array<{ file: String, original: Null<String> }> = [];
		function read(settling: Bool): Null<CompilerFacts> {
			if (!probed) {
				probed = true;
				// a check waits on the facts here, and a question it asks may escalate to the builds: they compile meanwhile
				if (!settling) startBuildsWithFacts(early != null, resolution);
				final built: Null<CompilerFacts> = TypedFactsProbe.finish(early ?? TypedFactsProbe.start(oracles));
				// the facts compiles are done and their cores free: the run's warm servers start, and compile, now
				if (early != null) compiler.startServers(oracles);
				facts = built;
				if (built != null) {
					for (d in built.dropped) CliIo.stderr('apq lint: compilerOracle ${d.name}: no compiler facts — ${d.reason}\n');
					for (glob in FactsEscapes.unmatchedGlobs(built, reflective ?? []))
						CliIo.stderr('apq lint: $REFLECTIVE_CLASSES "$glob" matches no class the builds typed\n');
					for (glob in FactsEscapes.unmatchedGlobs(built, holders ?? []))
						CliIo.stderr('apq lint: $REFLECTIVE_METHOD_HOLDERS "$glob" matches no class the builds typed\n');
					for (e in edited) built.invalidate(e.file, e.original);
				}
			}
			return facts;
		}
		// a run given every rule reads the builds off the facts compiles, which carry their probe (`TypedFactsProbe.start`);
		// one narrowed by `--rule` or `--category` may ask the builds and never the facts, so its builds take the probe alone
		if (o.ruleFilters.length == 0 && o.categoryFilters.length == 0) ahead.facts = read.bind(false);
		function touched(file: String, original: Null<String>): Void {
			final built: Null<CompilerFacts> = facts;
			if (built != null)
				built.invalidate(file, original)
			else if (!edited.exists(e -> e.file == file))
				edited.push({ file: file, original: original });
		}
		return {
			declared: resolution.declared,
			sources: resolution.sources,
			builds: resolution.builds,
			facts: read.bind(false),
			factsEdited: touched,
			factsSettled: () -> if (early != null) read(true),
			buildsHeld: resolution.buildsHeld,
			buildsAhead: resolution.buildsAhead,
			buildsSettled: resolution.buildsSettled
		};
	}

	/**
	 * The globs a reflective bound of the run's reach analysis declares (`read`, the config key `name`):
	 * `LintConfig.reflectiveClasses`, the classes a class value made from an unreadable name may be of, or
	 * `LintConfig.reflectiveMethodHolders`, the classes a read by such a name may obtain a method of — the declaration every
	 * linted path's config makes alike. A run whose paths declare different ones, or some none, is unbounded there
	 * (`unbounded` says how), and says so once when any of them declared one.
	 */
	public static function declaredBound(
		paths: Array<String>, resolveConfig: String -> LintConfig, read: LintConfig -> Null<Array<String>>, name: String, unbounded: String
	): Null<Array<String>> {
		if (paths.length == 0) return null;
		final first: Null<Array<String>> = read(resolveConfig(paths[0]));
		final key: Null<Array<String>> -> Null<String> = globs -> globs?.join('\n');
		var declared: Bool = false;
		var alike: Bool = true;
		for (path in paths) {
			final globs: Null<Array<String>> = read(resolveConfig(path));
			if (globs != null) declared = true;
			if (key(globs) != key(first)) alike = false;
		}
		if (declared && !alike) CliIo.stderr('apq lint: $name ignored — the linted paths declare different ones, so $unbounded\n');
		return alike ? first : null;
	}

	/**
	 * Whether the reach analysis may read the run's oracle builds as every build the project ships: EVERY linted path's
	 * config declares `reachConfigurationsComplete` over the same `compilerOracle` list as the first path's — the list the
	 * run probes. A path whose config says otherwise may ship a build that list does not name, so a run whose paths
	 * disagree walks every branch, and says so once when any of them declared the flag.
	 */
	public static function reachComplete(compiler: OracleProvider, paths: Array<String>, resolveConfig: String -> LintConfig): Bool {
		if (paths.length == 0) return false;
		final list: LintConfig -> String = c -> c.compilerOracles().map(compiler.oracleKey).join('|');
		final first: String = list(resolveConfig(paths[0]));
		var declared: Bool = false;
		var all: Bool = true;
		for (path in paths) {
			final config: LintConfig = resolveConfig(path);
			if (config.reachConfigurationsComplete()) declared = true;
			if (!config.reachConfigurationsComplete() || list(config) != first) all = false;
		}
		if (declared && !all)
			CliIo.stderr(
				'apq lint: reachConfigurationsComplete ignored — the linted paths resolve to different compilerOracle lists or'
				+ ' flags, so the reach analysis walks every conditional branch\n'
			);
		return all;
	}

	/**
	 * `resolution` carrying the builds an oracle run stored for exactly the compile input the run reads now
	 * (`ReachBuildsCache`), read on first demand: a run that compiles nothing knows the compilers' builds only from there,
	 * and otherwise knows none.
	 */
	private static function withStoredBuilds(
		resolution: ResolutionScope, oracles: Array<OracleConfig>, reflective: Null<Array<String>>, holders: Null<Array<String>>
	): ResolutionScope {
		var read: Bool = false;
		var builds: Null<ReachBuilds> = null;
		function load(): Null<ReachBuilds> {
			if (!read) {
				read = true;
				builds = bounded(ReachBuildsCache.load(oracles), reflective, holders);
			}
			return builds;
		}
		return {
			declared: resolution.declared,
			sources: resolution.sources,
			builds: load,
			buildsHeld: heldNote('this --no-oracle run found no builds stored for its exact input — a run with the oracle stores them')
		};
	}

	/**
	 * The run's `ResolutionScope.buildsHeld`: says once per consumer that it held for want of the builds, and `why` the run
	 * knows none.
	 */
	private static function heldNote(why: String): (String) -> Void {
		final told: Array<String> = [];
		return consumer -> {
			if (told.contains(consumer)) return;
			told.push(consumer);
			CliIo.stderr(
				'apq lint: $consumer held what only the builds can vouch for — reachConfigurationsComplete is declared, but $why\n'
			);
		};
	}

	/** `builds` carrying the bounds the project declares on what a computed name may make or obtain, where it declares them. */
	private static function bounded(
		builds: Null<ReachBuilds>, reflective: Null<Array<String>>, holders: Null<Array<String>>
	): Null<ReachBuilds> {
		if (builds != null && reflective != null) builds.reflectiveClasses = reflective;
		if (builds != null && holders != null) builds.reflectiveMethodHolders = holders;
		return builds;
	}

	/** End the builds' compiles `ahead` holds, started and never read (`withReachConfigurations`). */
	private static function dropAhead(ahead: AheadBuilds): Void {
		final pending: Null<DefinesProbe> = ahead.probe;
		ahead.probe = null;
		if (pending != null) ReachDefinesProbe.abandon(pending);
	}

}
