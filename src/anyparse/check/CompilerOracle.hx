package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;

using Lambda;
using StringTools;

/**
 * The verdict of one compiler-oracle typecheck run — `apq lint`'s bridge to
 * treating the Haxe compiler as ground truth. A project opts in through the `apqlint.json` `compilerOracle` key (an `.hxml` path, or
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
 * Runs the Haxe compiler as a lint oracle: `haxe <hxml> --no-output` in a child
 * process, mapping its exit status to an `OracleOutcome`. Stateless bar
 * `invocations` — a spawn counter tests read to prove the gate-invariant that
 * WITHOUT a configured `compilerOracle` the compiler is never launched (see
 * `FixVerifier` / `Cli.runLint`).
 *
 * The spawn itself is `HaxeSpawn`, shared with the two `-v` probes — the target
 * conditional, the output buffer and the four ways a run can produce no verdict all
 * live there. `cwd` is honoured on nodejs; the native sys branch IGNORES it and runs
 * in the process CWD, so an hxml's own relative `-cp` entries resolve against the
 * wrong root there (`HaxeSpawn.honoursCwd`).
 */
@:nullSafety(Strict)
final class CompilerOracle {

	/** Total typecheck spawns this process — tests assert 0 when no oracle is configured. */
	public static var invocations(default, null): Int = 0;

	/**
	 * Output buffer for the typecheck spawn, in bytes.
	 *
	 * Node's default is 1 MiB, and an overflow there is not a lost log line: it arrives as
	 * a spawn ERROR with a null status and a truncated stream, so a build whose errors run
	 * long was reported as a rejection quoting a cut-off transcript. `OracleCoverage`
	 * already pays 256 MiB for a `-v` probe on the same projects; a typecheck's error text
	 * is far smaller than that, so the cap only ever costs address space that is never
	 * touched.
	 */
	private static inline final ORACLE_BUFFER: Int = 256 * 1024 * 1024;

	/**
	 * Typecheck the project described by `hxml` (a path resolved by the caller,
	 * relative to `cwd` when given) under the extra `defines`, and return the compiler's
	 * verdict. `--no-output` forces a type-only pass, so a code-emitting `.hxml` is reused
	 * unchanged. A missing `haxe`, a non-process target, or a status-less spawn all map to
	 * `Unavailable` rather than throwing — the oracle degrades, never crashes the lint.
	 */
	public static function typecheck(hxml: String, ?cwd: String, ?defines: Array<String>): OracleOutcome {
		invocations++;
		return outcomeOf(HaxeSpawn.run(oracleArgs(hxml, defines ?? []), cwd, ORACLE_BUFFER));
	}

	/**
	 * Every configuration of `oracles` typechecked, the compiles overlapping (`HaxeSpawn.runAll`,
	 * bounded by `HaxeSpawn.parallelism`), one outcome per configuration in declared order. A
	 * configuration marked `unavailable` is answered `Unavailable` without a spawn.
	 *
	 * With `stopAfterFailure` a configuration that does not confirm ends every later one still
	 * compiling, and those answer null: the outcomes up to and including the first failure are
	 * exactly the ones a sequential loop stopping there would have seen, the rest are no verdict.
	 *
	 * Configurations a lint run prepared carry its `OracleRunMemo`, and then `remembered` answers:
	 * `verbose` asks it to compile with `-v`, so a coverage probe of the same tree reuses the run.
	 */
	public static function typecheckEach(
		oracles: Array<OracleConfig>, stopAfterFailure: Bool, verbose: Bool = false
	): Array<Null<OracleOutcome>> {
		final memo: Null<OracleRunMemo> = OracleRunMemo.of(oracles);
		if (memo != null) return remembered(memo, oracles, stopAfterFailure, verbose);
		final asked: Array<OracleConfig> = [for (oracle in oracles) if (oracle.unavailable == null) oracle];
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			for (oracle in asked) { args: oracleArgs(oracle.hxml, oracle.defines), cwd: oracle.dir }
		], ORACLE_BUFFER, HaxeSpawn.parallelism(), stopAfterFailure);
		for (run in runs) if (run.unstarted != true) invocations++;
		final out: Array<Null<OracleOutcome>> = [];
		var next: Int = 0;
		for (oracle in oracles) {
			final unavailable: Null<String> = oracle.unavailable;
			if (unavailable != null) {
				out.push(Unavailable(unavailable));
				continue;
			}
			final run: HaxeRun = runs[next++];
			out.push(run.cancelled == true ? null : outcomeOf(run));
		}
		return out;
	}

	/**
	 * The `haxe` argument vector for one configuration — the ONE place the `-D` placement is
	 * decided, and pure so that placement is assertable without a compiler.
	 *
	 * `--each` pushes every flag BEFORE it into each `--next` arm of the hxml, so the defines go
	 * ahead of it: a trailing `-D` joins one arm only, and the verdict would then be about a
	 * configuration nobody asked for. `--no-output` stays AFTER the hxml for the reason
	 * `OracleCoverage.probe` documents — it must not suppress output in an arm the oracle lets
	 * emit. With no defines the vector is byte-identical to what it always was.
	 */
	public static function oracleArgs(hxml: String, defines: Array<String>): Array<String> {
		return defines.length == 0 ? [hxml, '--no-output'] : defineFlags(defines).concat(['--each', hxml, '--no-output']);
	}

	/**
	 * `-D <name>` per declared define, in declared order — the vector fragment every spawn that
	 * carries a configuration's defines shares, so the typecheck, the coverage probe and the warm
	 * server cannot spell it three ways.
	 */
	public static function defineFlags(defines: Array<String>): Array<String> {
		final flags: Array<String> = [];
		for (define in defines) {
			flags.push('-D');
			flags.push(define);
		}
		return flags;
	}

	/**
	 * Typecheck EVERY configuration and answer with the outcome of the first, in declared order,
	 * that does not confirm; `Confirmed` only when all of them confirm.
	 *
	 * All of them, because an edit in shared code compiles under one set of defines and breaks
	 * under another — the whole reason the key is a list. The compiles overlap, and the first
	 * failure ends the ones declared after it (`typecheckEach`), so the verdict is the one a
	 * sequential loop gives while a rejection still costs no compile that could not change it.
	 * Configurations after the first `unavailable` one are never asked: its verdict is already
	 * decided. An empty list is `Unavailable`: no configuration means nothing was proved, which is
	 * not the same answer as a build that typechecks.
	 */
	public static function typecheckAll(oracles: Array<OracleConfig>): OracleOutcome {
		if (oracles.length == 0) return Unavailable('no compiler oracle is configured');
		final cut: Int = oracles.findIndex(oracle -> oracle.unavailable != null);
		final asked: Array<OracleConfig> = cut < 0 ? oracles : oracles.slice(0, cut + 1);
		for (outcome in typecheckEach(asked, true)) if (outcome != null && !outcome.match(Confirmed)) return outcome;
		return Confirmed;
	}

	/**
	 * Measure EVERY configuration's own baseline and split them: the ones that typecheck may
	 * judge an edit, the ones that do not are excluded with a sentence naming why.
	 *
	 * Per configuration and never as one verdict, because the two facts are independent — see
	 * `OracleBaseline`. Every configuration is asked (no short-circuit): a caller that drops the
	 * red ones has to know WHICH they are, and an unasked configuration cannot be classified.
	 */
	public static function judging(oracles: Array<OracleConfig>): OracleBaseline {
		final green: Array<OracleConfig> = [];
		final excluded: Array<OracleExclusion> = [];
		var first: Null<OracleOutcome> = null;
		// a baseline compiles with `-v` in a run that remembers, so the coverage probe of the same tree costs no compile
		final outcomes: Array<Null<OracleOutcome>> = typecheckEach(oracles, false, true);
		for (i in 0...oracles.length) {
			final oracle: OracleConfig = oracles[i];
			final outcome: OracleOutcome = outcomes[i] ?? Unavailable('the typecheck was cancelled');
			if (outcome.match(Confirmed)) {
				green.push(oracle);
				continue;
			}
			if (first == null) first = outcome;
			excluded.push({ config: oracle, cause: Baseline, sentence: exclusion(oracle, outcome) });
		}
		// An EMPTY configuration list has no first failure: no configuration means nothing was
		// proved, which is not the same answer as a build that typechecks. Re-bound because strict
		// null-safety does not carry a narrowed local into a structure literal.
		final failing: OracleOutcome = first ?? (oracles.length == 0 ? Unavailable('no compiler oracle is configured') : Confirmed);
		return {
			judging: green,
			excluded: excluded,
			verdict: green.length == 0 ? failing : Confirmed
		};
	}

	/**
	 * The identity a report dedupes an exclusion by: the configuration and the class of its reason,
	 * never the sentence — see `OracleExclusion`.
	 */
	public static function exclusionKey(exclusion: OracleExclusion): String {
		return '${OracleDeclaration.oracleKey(exclusion.config)}\n${exclusion.cause}';
	}

	/** The sentences of `exclusions`, in order — what a decline's reason list quotes. */
	public static function sentencesOf(exclusions: Array<OracleExclusion>): Array<String> {
		return [for (exclusion in exclusions) exclusion.sentence];
	}

	/** Whether `run` is a compile that ran to its own status — not cancelled, not a spawn that produced none. */
	private static inline function answered(run: HaxeRun): Bool {
		return run.cancelled != true && run.failure == '' && run.status != null;
	}

	/**
	 * `typecheckEach` in a run that remembers what the compiler answered (`OracleRunMemo`): a configuration whose current
	 * input the memo already holds a verdict for is answered without a spawn, and every other one is compiled — with `-v`
	 * when `verbose`, so a coverage probe of the same tree reuses it — and filed.
	 *
	 * A `-v` compile that fails is compiled again without the flag, because a rejection QUOTES the compiler's streams (the
	 * error-guided revert reads file names out of them) and `-v` writes a line per parsed file into stdout. Should the two
	 * disagree, the configuration answers `Unavailable` rather than `Confirmed`: under `stopAfterFailure` the jobs after it
	 * were already cancelled, and a confirm there would let the phase proceed on configurations never asked. With
	 * `stopAfterFailure` a configuration after one the memo answered as failing is not compiled at all.
	 */
	private static function remembered(
		memo: OracleRunMemo, oracles: Array<OracleConfig>, stopAfterFailure: Bool, verbose: Bool
	): Array<Null<OracleOutcome>> {
		final before: Array<Null<String>> = memo.fingerprints(oracles);
		final out: Array<Null<OracleOutcome>> = [
			for (i in 0...oracles.length) {
				final unavailable: Null<String> = oracles[i].unavailable;
				unavailable != null ? Unavailable(unavailable) : heldVerdict(memo, oracles[i], before[i]);
			}
		];
		final decided: Int = stopAfterFailure ? firstHeldFailure(oracles, out) : oracles.length;
		final compiled: Array<Int> = [for (i in 0...oracles.length) if (out[i] == null && i < decided) i];
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			for (i in compiled) { args: argsOf(oracles[i], verbose), cwd: oracles[i].dir }
		], ORACLE_BUFFER, HaxeSpawn.parallelism(), stopAfterFailure);
		for (run in runs) if (run.unstarted != true) invocations++;
		// a failing `-v` compile is asked again plainly: its streams are what a rejection quotes
		final retried: Array<Int> = verbose ? [for (k in 0...compiled.length) if (answered(runs[k]) && runs[k].status != 0) k] : [];
		final plain: Array<HaxeRun> = HaxeSpawn.runAll([
			for (k in retried) { args: argsOf(oracles[compiled[k]], false), cwd: oracles[compiled[k]].dir }
		], ORACLE_BUFFER, HaxeSpawn.parallelism(), false);
		invocations += plain.length;
		final after: Array<Null<String>> = memo.fingerprints([for (i in compiled) oracles[i]]);
		for (k in 0...compiled.length) {
			final i: Int = compiled[k];
			memo.file(oracles[i], verbose, before[i], after[k], runs[k]);
			final again: Int = retried.indexOf(k);
			if (again >= 0) memo.file(oracles[i], false, before[i], after[k], plain[again]);
			out[i] = again >= 0 ? retriedOutcome(plain[again]) : runs[k].cancelled == true ? null : outcomeOf(runs[k]);
		}
		return out;
	}

	/**
	 * What `memo` already answers for `oracle` at `fingerprint`: the plain compile's outcome, or `Confirmed` for a `-v`
	 * compile that exited 0 — a failing `-v` compile answers nothing, since a rejection may not quote its streams.
	 */
	private static function heldVerdict(memo: OracleRunMemo, oracle: OracleConfig, fingerprint: Null<String>): Null<OracleOutcome> {
		final plain: Null<HaxeRun> = memo.run(oracle, false, fingerprint);
		if (plain != null) return outcomeOf(plain);
		final verbose: Null<HaxeRun> = memo.run(oracle, true, fingerprint);
		return verbose != null && verbose.status == 0 ? Confirmed : null;
	}

	/** The argument vector of `oracle`'s typecheck, `-v` (`OracleCoverage.probeArgs`) when `verbose`. */
	private static function argsOf(oracle: OracleConfig, verbose: Bool): Array<String> {
		return verbose ? OracleCoverage.probeArgs(oracle.hxml, oracle.defines) : oracleArgs(oracle.hxml, oracle.defines);
	}

	/**
	 * The index of the first configuration of `oracles` the memo answered as failing in `held` — a configuration that
	 * could not be asked is no failure here — or the length when there is none.
	 */
	private static function firstHeldFailure(oracles: Array<OracleConfig>, held: Array<Null<OracleOutcome>>): Int {
		for (i in 0...oracles.length) {
			final outcome: Null<OracleOutcome> = held[i];
			if (oracles[i].unavailable == null && outcome != null && !outcome.match(Confirmed)) return i;
		}
		return oracles.length;
	}

	/**
	 * The outcome of the plain compile that followed a failing `-v` one: its own, unless it CONFIRMED, since the two then
	 * disagree and a confirm would let a phase proceed on configurations its cancellation left unasked.
	 */
	private static function retriedOutcome(plain: HaxeRun): OracleOutcome {
		final outcome: OracleOutcome = outcomeOf(plain);
		return outcome.match(Confirmed) ? Unavailable('the typecheck failed with -v and passed without it') : outcome;
	}

	/**
	 * The verdict one typecheck spawn produced. An overflow is the compiler having RUN and
	 * out-written the buffer; a build that verbose is failing, so it is a rejection carrying the
	 * partial errors rather than unavailability. Every other launch failure means haxe never ran.
	 */
	private static function outcomeOf(run: HaxeRun): OracleOutcome {
		if (run.overflowed) return Rejected((run.err + run.out).trim());
		if (run.failure != '') return Unavailable(run.failure);
		return switch (run.status) {
			case null: Unavailable('haxe exited without a status code');
			case 0: Confirmed;
			case _: Rejected((run.err + run.out).trim());
		};
	}

	/**
	 * Why one configuration may not judge, named for a report and for a decline clause: the
	 * configuration, the class of failure, and the compiler's FIRST error line — a whole error
	 * dump per configuration would bury the list it belongs to.
	 */
	private static function exclusion(oracle: OracleConfig, outcome: OracleOutcome): String {
		final named: String = OracleDeclaration.describeOracle(oracle);
		return switch outcome {
			case Confirmed: named;
			case Unavailable(reason): '$named was excluded — it could not run ($reason)';
			case Rejected(errors): '$named was excluded — it does not typecheck before any edit (${firstLine(errors)})';
		};
	}

	/** The first non-blank line of `text`, or the whole of it trimmed when every line is blank. */
	private static function firstLine(text: String): String {
		for (line in text.split('\n')) {
			final trimmed: String = line.trim();
			if (trimmed != '') return trimmed;
		}
		return text.trim();
	}

}
