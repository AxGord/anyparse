package anyparse.query;

import anyparse.check.Check.NameOracle;
import anyparse.check.Check.TypeOracle;
import anyparse.check.FactsOracle;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.OracleDeclared;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

/**
 * The compiler oracle of a grammar: its compiler, asked whether a tree typechecks under each configured build. The one
 * answer to "how does a verified fix phase reach the compiler oracle" — an optional capability the grammar plugin
 * implements and `OracleProviders.of` resolves; the phases ask only this surface, the language keeps the compiler.
 */
@:nullSafety(Strict)
interface OracleProvider {

	/** How many compiles the oracle has run so far; a phase reads the difference across a call to count its own. */
	public function invocations(): Int;

	/** Every configuration typechecked once: the green ones judge, the red ones are excluded with a sentence each. */
	public function judging(oracles: Array<OracleConfig>): OracleBaseline;

	/** One build's verdict, compiled cold. */
	public function typecheck(hxml: String, cwd: Null<String>, defines: Array<String>): OracleOutcome;

	/** One verdict over every configuration, the first non-green one winning; `verbose` compiles print what they read. */
	public function typecheckAll(oracles: Array<OracleConfig>, verbose: Bool): OracleOutcome;

	/** Each configuration's verdict and the files its compile read, in order; `stopAfterFailure` leaves the rest unasked. */
	public function typecheckEachReading(oracles: Array<OracleConfig>, stopAfterFailure: Bool): Array<OracleReading>;

	/** One build's verdict from a warm compilation server reading `paths`, or null when no server would answer. */
	public function serverTypecheck(hxml: String, cwd: Null<String>, paths: Array<String>, defines: Array<String>): Null<OracleOutcome>;

	/** The identity a report dedupes an exclusion by: its configuration and the class of its reason, never the sentence. */
	public function exclusionKey(exclusion: OracleExclusion): String;

	/** Which of `oracles` can vouch for an edit and what each compiles, settled once per `memo`; new exclusions join `excluded`. */
	public function usableOnce(memo: OracleCoverageMemo, oracles: Array<OracleConfig>, excluded: Array<OracleExclusion>): UsableCoverage;

	/**
	 * What each of `oracles` compiles, in order and unfiltered, probed once per `memo`: a build whose compiled set is unknown
	 * stays in the answer as unknown, which `usableOnce` would drop — a reach question must treat it as "cannot say".
	 */
	public function probedOnce(memo: OracleCoverageMemo, oracles: Array<OracleConfig>): Array<CompiledSet>;

	/** A fresh RUN-scoped name proof: whether a rewrite keeps what each written name means. */
	public function nameProof(): NameProof;

	/** A display server for one build, answering types at positions, or null when none would start. */
	public function startDisplay(
		typeSyntax: TypeSyntaxReader, hxml: String, cwd: Null<String>, defines: Array<String>
	): Null<DisplayTypeOracle>;

	/** The identity of one configured build: two configurations with one key are one build. */
	public function oracleKey(oracle: OracleConfig): String;

	/** The builds one raw `compilerOracle` value declares, relative paths against `baseDir`; what it cannot use goes to `drops`. */
	public function readDeclaration(declared: OracleDeclared, drops: Array<String>): Array<OracleConfig>;

	/** One configured build named for a diagnostic line. */
	public function describeOracle(oracle: OracleConfig): String;

	/** A fingerprint of everything one build would read, or null when that cannot be told; `memo` shares file reads across builds. */
	public function fingerprint(hxml: String, cwd: Null<String>, defines: Array<String>, memo: Map<String, String>): Null<String>;

	/** The verdict recorded for one build under `fingerprint`, or null when none is. */
	public function lookupVerdict(hxml: String, cwd: Null<String>, fingerprint: String, defines: Array<String>): Null<OracleOutcome>;

	/** Records a verdict unless the input moved from `fingerprint` or the compile read a file it did not hash; whether it was recorded. */
	public function storeVerdictIfUnchanged(
		hxml: String, cwd: Null<String>, fingerprint: String, outcome: OracleOutcome, defines: Array<String>, memo: Map<String, String>,
		parsed: Null<Array<String>>
	): Bool;

	/** The class paths one build spells explicitly. */
	public function classPaths(hxml: String, cwd: Null<String>): Array<String>;

	/** Every class path one build reads, libraries and standard library included, or null when the compiler could not be asked. */
	public function classRoots(hxml: String, cwd: Null<String>): Null<Array<String>>;

	/** Brings each build's generated inputs up to date and holds them for this run, until `releaseBuilds`. */
	public function prepareBuilds(oracles: Array<OracleConfig>): PreparedOracles;

	/** The run's compiles are done: another run may regenerate these builds. */
	public function releaseBuilds(oracles: Array<OracleConfig>): Void;

	/** `oracles` carrying a fresh RUN-scoped memo of what the compilers answer; `written` lists the run's files at each question. */
	public function attachRun(
		oracles: Array<OracleConfig>, persisted: Bool, written: () -> Array<String>, grammar: GrammarPlugin
	): Array<OracleConfig>;

	/** Starts the warm servers of the run `attachRun` gave `oracles`, if any. */
	public function startServers(oracles: Array<OracleConfig>): Void;

	/** Stops the warm servers of the run `attachRun` gave `oracles`, if any. */
	public function stopServers(oracles: Array<OracleConfig>): Void;

	/** Starts the compiles typing what `oracles` compile, for a run to read later. */
	public function startFacts(oracles: Array<OracleConfig>): StartedProbe<CompilerFacts>;

	/** Starts the compiles describing the builds of `oracles`; finishing stores what they answer for a run that compiles nothing. */
	public function startBuilds(oracles: Array<OracleConfig>): StartedProbe<ReachBuilds>;

	/** The builds of `oracles`, compiled now and stored as `startBuilds` stores them; null when any build cannot be told. */
	public function probeBuilds(oracles: Array<OracleConfig>): Null<ReachBuilds>;

	/** The builds an earlier run stored for exactly the input `oracles` read now, or null when none is. */
	public function storedBuilds(oracles: Array<OracleConfig>): Null<ReachBuilds>;

	/** The facts of the run behind `grammar` as a fix of `file`, read as `source`, asks them; null when it holds no complete facts. */
	public function factsForFix(grammar: GrammarPlugin, file: String, source: String): Null<FactsOracle>;

	/** `factsForFix` when the facts are the second proof of a fix, read only where a `--fix` run compiles them anyway. */
	public function factsForFixRun(grammar: GrammarPlugin, file: String, source: String): Null<FactsOracle>;

	/**
	 * The compiler facts of the run behind `grammar` over `files`, each read as it is now, or null when the run holds no
	 * complete facts; `fallback` answers for a file whose compiled text is gone.
	 */
	public function factsForFiles(
		grammar: GrammarPlugin, files: Array<{ file: String, source: String }>, fallback: () -> Null<TypeOracle>
	): Null<FactsOracle>;

}

/** Compiles a run started and has not read: exactly one of `finish` or `abandon` ends them. */
@:nullSafety(Strict)
interface StartedProbe<T> {

	/** Waits for the compiles and answers what they found, or null when they could not tell. */
	public function finish(): Null<T>;

	/** Ends the compiles unread, leaving nothing of theirs behind. */
	public function abandon(): Void;

}

/**
 * The builds' compiles a run began ahead of its first question and has not read or dropped yet, and the run's read of its
 * facts when its facts compiles carry the builds' probe: the builds' first question waits on that read instead of compiling them again.
 */
typedef AheadBuilds = {
	probe: Null<StartedProbe<ReachBuilds>>,
	?facts: () -> Void
};

/** What one configuration's compile reads, as far as an edit's verifiability goes. */
@:nullSafety(Strict)
interface CompiledSet {

	/** Whether the compiled set could be established at all. */
	public var known(get, never): Bool;

	/** Why the compiled set is unknown; empty when it is known. */
	public final reason: String;

	/**
	 * Why this compile cannot resolve one of `modules` (dotted import paths) for `file` — a sentence to quote — or null when
	 * it can, when it does not read `file`, or when it cannot say.
	 */
	public function unreached(file: String, modules: Array<String>): Null<String>;

	/** Why an edit covering `spans` in `file` is not verifiable by this compile — a sentence to quote — or null when it is. */
	public function uncovered(file: String, source: String, spans: Array<Span>, shape: RefShape, regions: Array<LexRegion>): Null<String>;

}

/** A `NameOracle` a verified pass points at its judging configurations once it knows them. */
@:nullSafety(Strict)
interface NameProof extends NameOracle {

	/** Ask the configurations `judges` names from now on, reading conditional regions with `plugin`. */
	public function answerFor(judges: () -> UsableCoverage, plugin: GrammarPlugin): Void;

}

/** A `TypeOracle` backed by a running server, which the phase that started it stops when it is done. */
@:nullSafety(Strict)
interface DisplayTypeOracle extends TypeOracle {

	public function stop(): Void;

}

/**
 * The one answer to "what does a decline quote when no configured build can judge an edit": the configurations' own
 * reasons, language-neutral text over `OracleExclusion` data, whatever compiler produced them.
 */
@:nullSafety(Strict)
final class OracleDeclines {

	/** The sentences of `exclusions`, in order — what a decline's reason list quotes. */
	public static function sentencesOf(exclusions: Array<OracleExclusion>): Array<String> {
		return exclusions.map(exclusion -> exclusion.sentence);
	}

	/**
	 * The decline sentence for the per-configuration gaps of ONE edit set — what every caller
	 * holding a LIST of configurations quotes once none of them typechecks the edit.
	 *
	 * A single gap IS the whole answer and is quoted verbatim, so a one-configuration project
	 * reads exactly as it always did. Several are joined rather than summarised: each is a
	 * different build's reason for being unable to judge this edit, and naming one would send the
	 * reader to close a gap that on its own permits nothing. Pure.
	 */
	public static function gapSentence(gaps: Array<String>): String {
		return gaps.length == 1 ? gaps[0] : 'no configured compiler oracle typechecks this edit — ${gaps.join('; ')}';
	}

}

/**
 * The verdict of one compiler-oracle typecheck run — `apq lint`'s bridge to
 * treating the Haxe compiler as ground truth. A project opts in through the `apq.json` `compilerOracle` key (an `.hxml` path, or
 * a LIST of configurations); the linter then runs `haxe <hxml> --no-output` per configuration and folds the results back into the run:
 *
 *  - `Confirmed`   — the project typechecks; report mode annotates its
 *    `@:nullSafety` trust as compiler-confirmed, fix mode keeps a risky fix.
 *  - `Rejected`    — the project does NOT typecheck; carries the compiler's
 *    error text. Report mode fails the lint; fix mode reverts the risky edit.
 *  - `Unavailable` — the oracle could not run (no `haxe` on PATH, a non-sys/
 *    nodejs target, or a spawn that produced no exit status). Treated
 *    conservatively: a report run degrades to a note (never a failure), a
 *    risky fix is left unapplied (report-only) since safety cannot be shown.
 */
enum OracleOutcome {
	Confirmed;
	Rejected(errors: String);
	Unavailable(reason: String);
}

/**
 * Which configurations may JUDGE an edit, why the others may not, and the verdict a phase proceeds on.
 *
 * `judging` holds the ones whose OWN baseline typechecks; `excluded` names each one that does not
 * (a fresh list the caller owns and may extend); `verdict` is `Confirmed` while at least one
 * configuration judges, else the outcome of the FIRST failing configuration in declared order (no
 * ranking between `Rejected` and `Unavailable`). A configuration red before any edit was never a
 * working gate — a failure there afterwards is unattributable — so it is dropped and named rather
 * than allowed to stop the phase. On a cross-platform tree the alternative is severe: one broken
 * target would disable every risky fix, including in files that target never reads.
 *
 * Every phase that judges (the safe-pass net, the risky phase, the oracle-assisted phase) measures
 * this afresh over every configured build; in a lint run the configurations remember what the compiler
 * answered (`OracleRunMemo`), so a phase whose tree an earlier compile already judged pays no compile for it.
 */
typedef OracleBaseline = {
	var judging: Array<OracleConfig>;
	var excluded: Array<OracleExclusion>;
	var verdict: OracleOutcome;
}

/**
 * One configuration's verdict and every file its compile parsed, as the compiler printed the path — null when the
 * verdict came off a compile that did not print them, or none was asked.
 */
typedef OracleReading = {
	var outcome: Null<OracleOutcome>;
	var parsed: Null<Array<String>>;
}

/**
 * One configuration that judged nothing, and why: the configuration, the CLASS of the reason, and
 * the sentence a report prints. A report names a configuration once per (configuration, cause) —
 * never once per sentence, since a red build's sentence quotes an error line whose number moves
 * when a fix edits the lines above it.
 */
typedef OracleExclusion = {
	var config: OracleConfig;
	var cause: ExclusionCause;
	var sentence: String;
}

/** Why a configuration judged nothing: its own baseline failed, or its compiled set is unknown. */
enum abstract ExclusionCause(String) to String {
	var Baseline = 'baseline';
	var Coverage = 'coverage';
}

/**
 * The cell a caller memoises its compiled-set probes in — empty until the first probe, or seeded
 * with the probes a previous phase already paid for. Each probe carries the configuration it was
 * taken for, which is the only key a reuse may be made by (`OracleCoverage.probedOnce`).
 */
typedef OracleCoverageMemo = {

	var probes: Array<ConfigCoverage>;

	/** The phase's `usableOnce` split, null until its first candidate asks. */
	var usable: Null<UsableCoverage>;

}

/** One compiled-set probe and the configuration it describes — never read apart. */
typedef ConfigCoverage = {
	var config: OracleConfig;
	var coverage: CompiledSet;
}

/**
 * The configurations a phase may judge with once coverage is known — see `OracleCoverage.usable`.
 *
 * `configs` and `coverages` are paired by position and hold only KNOWN coverage; `unknown` holds
 * the configurations that cannot say what they compile, which vouch for no edit but still verify
 * every candidate; `excluded` names each of them; `stop` is the reason the phase stops, non-null
 * only when no configuration is left.
 */
typedef UsableCoverage = {
	var configs: Array<OracleConfig>;
	var coverages: Array<CompiledSet>;
	var unknown: Array<OracleConfig>;
	var excluded: Array<OracleExclusion>;
	var stop: Null<String>;
}

/** `OracleProvider.prepareBuilds`' answer: the configurations ready to use, and a line per command that ran. */
typedef PreparedOracles = {
	var oracles: Array<OracleConfig>;
	var notes: Array<String>;
}
