package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.CheckScan;
import anyparse.check.CompilerDisplayOracle;
import anyparse.check.CompilerOracle;
import anyparse.check.CompilerServer;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.OracleCache;
import anyparse.check.OracleCoverage;
import anyparse.core.EnvFlag;
import anyparse.query.Cli.RuleFixOutcome;
import anyparse.runtime.Span;
import haxe.io.Path;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * The oracle batch's verdict: which files kept their annotations, which were rolled back, and WHY
 * the rollback happened — the three causes (a compiler rejection naming no candidate, an
 * unavailable oracle, a batch that did not converge) are different problems and used to print the
 * same line. `reason` is meaningful only when `reverted` is non-empty.
 */
typedef OracleBatchResult = {
	final applied: Array<String>;
	final reverted: Array<String>;
	final reason: String;
};

/**
 * What the risky-fix phase did, in the shape `applyLintFixes` consumes: the summary tail,
 * this phase's contribution to the edit count, the per-file reverts and declines it names on
 * their own lines, and whether its rules reached the fix LEDGER at all.
 *
 * `ledgered` is what the ledger's footer turns on. A `RiskyFix` check is excluded from the
 * safe loop, so before `FixVerifier` carried tallies the per-rule "reported but got no edit"
 * block had to disclaim every risky rule unconditionally; it now disclaims only a phase that
 * genuinely never asked them — no oracle, an oracle that would not start, a tree that does not
 * typecheck, or a compiled set that could not be established.
 */
@:nullSafety(Strict)
typedef RiskyFixOutcome = {
	var tail: String;
	var appliedCount: Int;
	var reverts: Array<FixVerifyRevert>;
	var declines: Array<FixVerifyDecline>;
	var ledgered: Bool;

	/**
	 * The compiled-set probe the risky phase paid for, or null when it never ran one. The
	 * oracle-assisted phase reuses it rather than spawning a second `-v` compile.
	 *
	 * It is taken BEFORE the risky phase writes and read after, which extends the
	 * within-run snapshot `FixVerifier` documents across a phase boundary. Defines cannot
	 * move (a fix does not change them), but MEMBERSHIP can: a risky fix that removes the
	 * last reference to a module drops it out of the compiled set, and the assisted phase
	 * would then permit an edit in a file the compile no longer reads. Re-probing costs a
	 * whole compile, which is the expense this hand-off exists to avoid.
	 */
	var coverage: Null<OracleCoverage>;
};

/**
 * The compiler oracle's half of `apq lint --fix`.
 *
 * A risky fix is applied, compiled and kept only if the verdict allows it — and
 * an oracle-assisted batch is bisected when it does not. Split from
 * `LintFixDriver` because the pass loop runs with no oracle at all.
 */
@:nullSafety(Strict)
final class LintFixVerify {

	/**
	 * Verify and apply the RiskyFix checks' fixes: a no-op with no risky check, report-only (no
	 * compile) with no oracle, else `FixVerifier`-gated — files whose risky fix survives fold into
	 * `changedFiles`. Returns the summary tail, this phase's edit count, and the reverts and
	 * declines the caller names on their own lines. Split out of `applyLintFixes` to keep that
	 * function under the complexity budget.
	 *
	 * It also fills the run's fix `ledger` for its own rules, on the one path where the phase
	 * actually ran them (`ledgerRiskyTallies`). Every other path answers `ledgered: false`, which
	 * is what lets the ledger block disclaim the risky set only when the disclaimer is true.
	 */
	public static function verifyRiskyFixes(
		files: Array<{ file: String, source: String }>, riskyChecks: Array<Check>, cached: GrammarPlugin, oracleHxml: Null<String>,
		oracleDir: Null<String>, optsByFile: Map<String, Null<String>>, changedFiles: Array<String>, ledger: Map<String, RuleFixOutcome>
	): RiskyFixOutcome {
		if (riskyChecks.length == 0) return {
			tail: '',
			appliedCount: 0,
			reverts: [],
			declines: [],
			ledgered: false,
			coverage: null
		};
		if (oracleHxml == null) return {
			tail: ', ${riskyChecks.length} risky-fix rule(s) left report-only (no compiler oracle for this run)',
			appliedCount: 0,
			reverts: [],
			declines: [],
			ledgered: false,
			coverage: null
		};
		final verified: FixVerifyResult = FixVerifier.verify(
			files, riskyChecks, cached, oracleHxml, oracleDir, CliIo.writeFile, optsByFile
		);
		switch verified.baseline {
			case Confirmed:
				final unknownCoverage: Null<String> = verified.coverageUnknown;
				// An oracle whose COMPILED SET could not be established can verify nothing, so the
				// phase declines whole — the same outcome, and nearly the same sentence, as a run
				// with no `compilerOracle` at all. Reported here rather than as N identical
				// per-file lines: it is one fact about the oracle, not one per candidate.
				if (unknownCoverage != null) return {
					tail: ', ${riskyChecks.length} risky-fix rule(s) left report-only'
						+ ' (the oracle\'s compiled set is unknown: $unknownCoverage)',
					appliedCount: 0,
					reverts: [],
					declines: [],
					ledgered: false,
					coverage: verified.coverage
				};
				for (f in verified.applied) if (!changedFiles.contains(f)) changedFiles.push(f);
				ledgerRiskyTallies(ledger, verified);
				return {
					tail: ', risky-fix verified: ${verified.applied.length} file(s) applied, ${verified.reverted.length}'
						+ ' reverted to report-only${declinedTail(verified.declined)}${bisectTail(verified.partials)}',
					appliedCount: verified.appliedEdits,
					reverts: verified.reverted,
					declines: verified.declined,
					ledgered: true,
					coverage: verified.coverage
				};
			case Unavailable(reason):
				return {
					tail: ', risky-fix skipped (oracle unavailable: $reason)',
					appliedCount: 0,
					reverts: [],
					declines: [],
					ledgered: false,
					coverage: null
				};
			case Rejected(_):
				// NOT "the baseline is red": `FixVerifier` measures its baseline AFTER the safe
				// writes, so this arm is reached both by a tree that was already broken and by
				// one the safe pass broke. `reconcileSafePass` has already told the two apart
				// and reverted the second, so by here it can only be the first — say that.
				return {
					tail: ', risky-fix skipped (the tree does not typecheck — see the note above)',
					appliedCount: 0,
					reverts: [],
					declines: [],
					ledgered: false,
					coverage: null
				};
		}
	}

	/**
	 * Fold one risky-fix phase's per-(rule, file) tallies into the run's fix ledger.
	 *
	 * `noteFixOutcome` in the risky path's own words: `reported` takes the findings, `edits`
	 * takes what landed, and a file where nothing landed contributes its findings to `declined`
	 * under whatever sentence the verifier already recorded for that (file, rule) pair. Until
	 * this existed the 13 `RiskyFix` rules put edits into the run's summary count and never a
	 * finding into the block that says what got no edit — the two numbers a reader compares were
	 * measured over two different rule sets, and the block had to say so instead of answering.
	 *
	 * Reached only from a phase that actually RAN its checks. `declined` also stays a
	 * once-per-run count here, which is what keeps it comparable with `reported`; the risky phase
	 * runs once by construction, so it needs no equivalent of the safe loop's `countDeclines`.
	 */
	public static function ledgerRiskyTallies(ledger: Map<String, RuleFixOutcome>, verified: FixVerifyResult): Void {
		for (tally in verified.tallies) {
			final entry: RuleFixOutcome = LintFixDriver.ledgerFor(ledger, tally.rule);
			entry.reported += tally.findings;
			entry.edits += tally.edits;
			if (tally.edits != 0) continue;
			entry.declined += tally.findings;
			// The check's OWN sentences first, per finding, because they answer a DIFFERENT question
			// than the verifier's: a finding the check declined never produced a candidate edit, so
			// "the oracle does not compile this file" is not why IT got no edit — it is why the
			// OTHER findings' edits were never written. Charging all of them to the verifier would
			// blame the compiler for work never offered to it; charging all of them to the check
			// would have it speak for findings it said nothing about.
			var spoken: Int = 0;
			for (own in tally.declineReasons) {
				LintFixDriver.bumpReason(entry.reasons, own.text, own.count);
				spoken += own.count;
			}
			// The REMAINDER only — the findings the check left silent. `reasonLines` already reads a
			// reason total below `declined` as "the check spoke for some of these and not the rest",
			// so the split needs no new sentence form and cannot double-count.
			final rest: Int = tally.findings - spoken;
			if (rest <= 0) continue;
			final reason: Null<String> = riskyDeclineReason(verified, tally);
			if (reason != null) LintFixDriver.bumpReason(entry.reasons, reason, rest);
		}
	}

	/**
	 * The verifier's own sentence for a (file, rule) whose edits never landed, or null when the
	 * check simply answered no edit and there is nothing to quote.
	 *
	 * Looked up rather than carried on the tally: both lists are keyed by the same pair, and a
	 * copy on the tally would be a second `revertCauseText` living in `anyparse.check`.
	 */
	private static function riskyDeclineReason(verified: FixVerifyResult, tally: FixVerifyTally): Null<String> {
		final decline: Null<FixVerifyDecline> = verified.declined.find(d -> d.file == tally.file && d.rule == tally.rule);
		if (decline != null) return decline.reason;
		final revert: Null<FixVerifyRevert> = verified.reverted.find(r -> r.file == tally.file && r.rule == tally.rule);
		return revert != null ? revertCauseText(revert.cause) : null;
	}

	/**
	 * The one sentence naming WHY a risky edit set rolled back. Not the file, not
	 * the rule — those are already on the line; this is the half that used to be
	 * missing, and its absence let a writer refusal read as a compiler rejection.
	 */
	public static function revertCauseText(cause: FixRevertCause): String {
		return switch cause {
			case OracleRejected: 'the compiler rejected it';
			case OracleUnavailable(reason): 'the compiler oracle could not run ($reason)';
			case NotCanonical(message): 'nothing reached the compiler — $message';
		};
	}

	/**
	 * One-line summary of the per-edit (per-group, for a `GroupedFix` check) bisect activity
	 * across every partially-applied file, appended to the risky-fix tail. Empty when nothing
	 * was bisected. The counts are EDIT counts either way — `FixVerifyPartial` normalises the
	 * grouped case, so this line never has to say whether a rule grouped anything.
	 */
	private static function bisectTail(partials: Array<FixVerifyPartial>): String {
		if (partials.length == 0) return '';
		var kept: Int = 0;
		var reverted: Int = 0;
		var probes: Int = 0;
		for (partial in partials) {
			kept += partial.appliedEdits;
			reverted += partial.revertedEdits;
			probes += partial.oracleInvocations;
		}
		return ' (bisect: ${partials.length} file(s), $kept edit(s) kept, $reverted reverted, $probes oracle run(s))';
	}

	/**
	 * One-line summary of the risky edit sets DECLINED for want of oracle coverage, appended to
	 * the risky-fix tail ahead of the bisect clause. Empty when nothing was declined, so a run
	 * over a fully-compiled tree keeps the bytes every gate and doc quotes.
	 *
	 * Kept OUT of the reverted count on purpose. A revert is the compiler having read a candidate
	 * and refused it; a decline is a candidate no compiler ever read. Adding them together would
	 * let a run that verified nothing read exactly like a run that verified and rejected.
	 */
	private static function declinedTail(declined: Array<FixVerifyDecline>): String {
		if (declined.length == 0) return '';
		var edits: Int = 0;
		// DISTINCT files, because the word on the line is "file(s)": `declined` holds one entry
		// per (file, RULE), and with 13 risky rules in the registry one uncovered file tripping
		// three of them would otherwise read as three.
		final files: Array<String> = [];
		for (entry in declined) {
			edits += entry.edits;
			if (!files.contains(entry.file)) files.push(entry.file);
		}
		// "not typechecked by the oracle" rather than "outside the compiled set": since the
		// coverage answer went region-granular a decline is as often a `#if` branch of a file the
		// oracle DOES compile, and the old wording sent a reader looking at the hxml's `-cp` list
		// for a file that is already on it. The per-decline lines below carry which one it was.
		return ', ${files.length} file(s) DECLINED unverifiable ($edits edit(s) the oracle does not typecheck)';
	}

	/**
	 * `--no-oracle`: say plainly that the compiler was not asked, and never fail on
	 * it. Always null (no fail) — declining to run a gate can only ever weaken a
	 * verdict, so it must never be able to produce one.
	 */
	public static function oracleSkippedNote(oracleHxml: Null<String>): Null<Int> {
		if (oracleHxml != null) CliIo.stderr('apq lint: compiler oracle SKIPPED (--no-oracle) — nullSafety trust unproved for this run\n');
		return null;
	}

	/**
	 * Report-mode compiler oracle: with a `compilerOracle` configured, typecheck the
	 * project and (a) return a non-null EXIT_RUNTIME with the compiler's errors when
	 * the build is rejected — failing the run; (b) print a `compiler-confirmed` note
	 * on a clean build (the prover's @:nullSafety trust, verdicts unchanged); (c)
	 * degrade to a skip note when the oracle can't run. Null = no fail. Split out of
	 * `runLint` to keep it under the complexity budget.
	 */
	public static function reportModeOracle(
		oracleHxml: Null<String>, oracleDir: Null<String>, paths: Array<String>, warmServer: Bool
	): Null<Int> {
		if (oracleHxml == null) return null;
		switch reportOracleVerdict(oracleHxml, oracleDir, paths, warmServer) {
			case Confirmed:
				// The qualifier is not hedging: what the compile confirms is the code it TYPECHECKED,
				// and an hxml routinely reads a fraction of the lint scope (196 of 868 files on one
				// measured project) while a `#if` branch its defines exclude is skipped inside a file
				// it does read (measured on this repo: 483 of 1267 conditional branches in scope are
				// provably compiled). `OracleCoverage` answers that question per edit for `--fix`;
				// report mode does not probe, so the honest thing here is to say what the claim covers
				// rather than to imply the whole scope.
				CliIo.stderr(
					'apq lint: compiler oracle confirmed — build typechecks (nullSafety trust: compiler-confirmed for the code'
					+ ' this hxml compiles — not for a file it never reads, nor for a #if branch its defines exclude)\n'
				);
			case Unavailable(reason):
				CliIo.stderr('apq lint: compiler oracle unavailable — $reason (skipped)\n');
			case Rejected(errors):
				CliIo.stderr('apq lint: compiler oracle REJECTED — build does not typecheck:\n');
				CliIo.stderr('$errors\n');
				return EXIT_RUNTIME;
		}
		return null;
	}

	/**
	 * The report-mode oracle verdict, through a CONTENT-ADDRESSED cache first. The key is a
	 * fingerprint of everything the compiler would read (`OracleCache`), so a hit is only ever
	 * taken on a byte-identical compile input — never on a modification time, never on "nothing
	 * looks changed". Every doubt yields no fingerprint or no record, and then the compiler
	 * itself decides, which is why the cache can only change what a verdict COSTS.
	 *
	 * `APQ_NO_ORACLE_CACHE` declines it process-wide. That is a weakening-only switch: declining
	 * a cache can cost time, never change a verdict.
	 *
	 * The `--fix` risky-fix verification never reaches here — `FixVerifier` calls
	 * `CompilerOracle` directly, so a post-write typecheck is always a real compiler run.
	 */
	private static function reportOracleVerdict(hxml: String, dir: Null<String>, paths: Array<String>, warmServer: Bool): OracleOutcome {
		final fingerprint: Null<String> = EnvFlag.isSet('APQ_NO_ORACLE_CACHE') ? null : OracleCache.fingerprint(hxml, dir);
		if (fingerprint != null) {
			final cached: Null<OracleOutcome> = OracleCache.lookup(hxml, dir, fingerprint);
			if (cached != null) {
				CliIo.stderr(
					'apq lint: compiler oracle verdict reused — the compile input hashes identical to the last typecheck (no compile)\n'
				);
				return cached;
			}
		}
		final verdict: OracleOutcome = compiledOracleVerdict(hxml, dir, paths, warmServer);
		if (fingerprint != null) OracleCache.store(hxml, dir, fingerprint, verdict);
		return verdict;
	}

	/**
	 * The verdict an actual COMPILER produced: through the project's shared WARM compilation
	 * server when the config opted in (`compilerOracleServer`) and the process did not decline it
	 * (`APQ_NO_ORACLE_SERVER`), else a fresh `haxe <hxml> --no-output`. Verdict-equivalent by
	 * construction — the warm path answers null for every condition it cannot decide under
	 * (no server, a dead one, a port that answers as something else), and the cold oracle
	 * takes over then. The `--fix` risky-fix verification never comes here either: a post-write
	 * typecheck is the one question a compilation server cannot answer honestly.
	 */
	private static function compiledOracleVerdict(hxml: String, dir: Null<String>, paths: Array<String>, warmServer: Bool): OracleOutcome {
		final declined: Bool = !warmServer || EnvFlag.isSet('APQ_NO_ORACLE_SERVER');
		// A warm CONFIRM stands as it is; a warm REJECTION is re-run COLD before it is reported.
		// A compilation server can re-emit a stale null-safety diagnostic for a module it restored
		// from cache rather than recompiled — measured here: one site made every cached recompile
		// of this project spuriously red while the cold compile was green. So a rejection always
		// carries the cold compiler's own verdict and error text, and the server can only ever
		// change what a verdict COSTS.
		return switch (declined ? null : CompilerServer.typecheck(hxml, dir, paths)) {
			case Confirmed: Confirmed;
			case Rejected(_): coldAfterWarmRejection(hxml, dir);
			case null, _: CompilerOracle.typecheck(hxml, dir);
		};
	}

	/**
	 * The COLD verdict after the warm server rejected, plus a note when the two disagree. That
	 * disagreement is the only externally visible symptom of a stale cached diagnostic, and
	 * without the note the run silently costs a warm typecheck plus a cold one forever with
	 * nothing to point at.
	 */
	private static function coldAfterWarmRejection(hxml: String, dir: Null<String>): OracleOutcome {
		final cold: OracleOutcome = CompilerOracle.typecheck(hxml, dir);
		if (cold.match(Confirmed))
			CliIo.stderr(
				'apq lint: warm compiler server rejected a build the compiler accepts — stale cached diagnostic, cold verdict used\n'
			);
		return cold;
	}

	/**
	 * The OracleAssisted tail of `--fix`: for each oracle-assisted check, ask a warm Haxe
	 * display server for the compiler's inferred type of every finding the structural arm
	 * left, annotate it, then WRITE the edited files and VERIFY the project still typechecks
	 * with a FRESH `CompilerOracle.typecheck` — reverting any file the compiler rejects (the
	 * report-only fallback).
	 *
	 * Runs ONLY when a `compilerOracle` is configured and the baseline typechecks (so a
	 * failure is attributable to our annotation); otherwise a note and zero edits,
	 * byte-identical to a run without the key.
	 *
	 * And only where that compile actually TYPECHECKS the annotated code: the same
	 * `OracleCoverage` gate the risky phase has, taken on the probe that phase already paid
	 * for. "The build still passes" says nothing about a file the hxml never reads, nor about
	 * a `#if` branch its defines exclude — and this phase's verification is exactly that
	 * sentence.
	 *
	 * The display server is queried READ-ONLY (files unchanged since the warm) — verification
	 * is a fresh process because the server's mtime cache is stale within the same second (see
	 * `CompilerDisplayOracle`). Split from `applyLintFixes` for the complexity budget.
	 */
	public static function applyOracleAssistedFixes(
		files: Array<{ file: String, source: String }>, oracleChecks: Array<Check>, plugin: GrammarPlugin, oracleHxml: Null<String>,
		oracleDir: Null<String>, optsByFile: Map<String, Null<String>>, changedFiles: Array<String>, resolveConfig: (String) -> LintConfig,
		coverage: Null<OracleCoverage>
	): { tail: String, appliedCount: Int } {
		if (oracleChecks.length == 0) return { tail: '', appliedCount: 0 };
		if (oracleHxml == null) return {
			tail: ', ${oracleChecks.length} oracle-assisted rule(s) left report-only (no compiler oracle for this run)',
			appliedCount: 0
		};
		final blocked: Null<String> = assistedSkipTail(oracleHxml, oracleDir);
		if (blocked != null) return { tail: blocked, appliedCount: 0 };
		final display: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start(oracleHxml, oracleDir);
		if (display == null) return { tail: ', oracle-assisted skipped (display server unavailable)', appliedCount: 0 };
		// This phase writes annotations and then asks the SAME `haxe <hxml> --no-output`
		// whether the tree still builds — the very control `OracleCoverage` exists to keep
		// honest — and it was ungated: a file the hxml never compiles, or a `#if` branch its
		// defines exclude, got its annotation written and confirmed by a compile that could not
		// have refused it. `verifyRiskyFixes` hands over the probe it already paid for; the
		// closure exists so a run whose oracle-assisted checks propose nothing pays for none.
		//
		// `coverageHxml` is NOT a redundant alias: `oracleHxml` is a `Null<String>` parameter whose
		// null check narrows it only in straight-line code, and the closure below would see the
		// declared type again. Inlining it is a strict-null-safety error, not a simplification.
		final coverageHxml: String = oracleHxml;
		var coverageMemo: Null<OracleCoverage> = coverage;
		inline function compiledSet(): OracleCoverage {
			final memo: Null<OracleCoverage> = coverageMemo;
			if (memo != null) return memo;
			final probed: OracleCoverage = OracleCoverage.probe(coverageHxml, oracleDir);
			coverageMemo = probed;
			return probed;
		}
		final declines: Array<{ file: String, reason: String, edits: Int }> = [];
		var unknownCoverage: Null<String> = null;
		for (check in oracleChecks) if (check is ConfigAware) (cast check: ConfigAware).setConfigResolver(resolveConfig);
		final candidates: Array<{ file: String, before: String, after: String }> = [];
		// Per-file EDIT counts, so the run's "fixed N issue(s)" stays one unit: the safe loop
		// contributes edits, and a phase that reports FILES would silently shrink the total
		// (37 files carrying ~400 annotations once read as "37 issues").
		final editsPerFile: Map<String, Int> = [];
		// One WHOLE-SET run per check, findings grouped per file — the same scope contract
		// as `FixVerifier.verify` and the safe loop's `fullScopeIds`: a per-file run
		// starves any cross-file resolution the check's gates or classifiers lean on.
		// Through `Linter.collect`, never `check.run` directly — the one gated entry every consumer
		// of a check's findings shares (see its doc; this path is one of the two that used to bypass).
		// KNOWINGLY NOT INDEPENDENTLY COVERED: no test can distinguish this line from a direct
		// `check.run`, because no `OracleAssisted` builtin can produce an edit inside a
		// quotation anyway — the display server has no typed AST for reified source, so `typeAt`
		// returns nothing there (measured: with this line reverted, a quoted untyped local is still
		// left alone). What the suite does cover is the shared entry itself and the identical wiring
		// in `FixVerifier.verify`, which IS discriminating. Keep this line spelled the same as that
		// one so the two cannot drift apart unnoticed.
		final findingsByCheck: Array<{ check: Check, all: Array<Violation> }> = [
			for (check in oracleChecks) { check: check, all: Linter.collect(files, plugin, [check]).filter(v -> v.rule == check.id()) }
		];
		for (entry in files) {
			final allEdits: Array<{ span: Span, text: String }> = assistedEdits(entry, findingsByCheck, plugin, display);
			if (allEdits.length == 0) continue;
			final compiled: OracleCoverage = compiledSet();
			if (!compiled.known) {
				unknownCoverage = compiled.reason;
				break;
			}
			final gap: Null<String> = assistedEditsAreVerifiable(compiled, entry, allEdits, plugin);
			if (gap != null) {
				declines.push({
					file: entry.file,
					reason: gap,
					edits: allEdits.length
				});
				continue;
			}
			editsPerFile[entry.file] = allEdits.length;
			switch RefactorSupport.canonicalize(entry.source, allEdits, false, plugin, optsByFile[entry.file]) {
				case Ok(text) if (text != entry.source):
					candidates.push({ file: entry.file, before: entry.source, after: text });
				case _:
			}
		}
		display.stop();
		final unknown: Null<String> = unknownCoverage;
		if (unknown != null) return {
			tail: ', oracle-assisted skipped (the oracle\'s compiled set is unknown: $unknown)',
			appliedCount: 0
		};
		// WHICH files, not just how many — the same reason the risky phase prints a line per
		// decline: a count leaves the reader to guess which of hundreds of files this hxml never
		// typechecks, which is the search those lines exist to remove. Capped for the same reason
		// too: on a partially-covered tree a decline is the common case, not the rare one.
		var declinedEdits: Int = 0;
		for (i in 0...declines.length) {
			declinedEdits += declines[i].edits;
			if (i >= LintFixDriver.DECLINE_LINES_SHOWN) continue;
			CliIo.stderr(
				'apq lint --fix: oracle-assisted DECLINED ${declines[i].file}: ${declines[i].reason}'
				+ ' — ${declines[i].edits} edit(s) left report-only\n'
			);
		}
		if (declines.length > LintFixDriver.DECLINE_LINES_SHOWN)
			CliIo.stderr(
				'apq lint --fix: … and ${declines.length - LintFixDriver.DECLINE_LINES_SHOWN} more oracle-assisted decline(s) not listed\n'
			);
		final declinedTail: String = declines.length == 0
			? ''
			: ', ${declines.length} file(s) DECLINED unverifiable ($declinedEdits edit(s) the oracle does not typecheck)';
		final applied: { tail: String, appliedCount: Int } = candidates.length == 0
			? { tail: ', oracle-assisted: 0 applied', appliedCount: 0 }
			: commitAssisted(candidates, oracleHxml, oracleDir, files, changedFiles, editsPerFile);
		return {
			tail: applied.tail + declinedTail,
			appliedCount: applied.appliedCount
		};
	}

	/**
	 * Write the annotated candidates, reconcile them with a fresh typecheck (`verifyOracleBatch`),
	 * and turn the outcome into this phase's summary tail plus its edit count.
	 *
	 * The revert CAUSE is part of the verdict: a compiler rejection, an unavailable oracle and a
	 * non-convergent batch are three different things to act on, and used to print identically.
	 */
	private static function commitAssisted(
		candidates: Array<{ file: String, before: String, after: String }>, oracleHxml: String, oracleDir: Null<String>,
		files: Array<{ file: String, source: String }>, changedFiles: Array<String>, editsPerFile: Map<String, Int>
	): { tail: String, appliedCount: Int } {
		final result: OracleBatchResult = verifyOracleBatch(candidates, oracleHxml, oracleDir);
		syncAppliedSources(files, candidates, result.applied);
		var edits: Int = 0;
		for (f in result.applied) {
			if (!changedFiles.contains(f)) changedFiles.push(f);
			edits += editsPerFile[f] ?? 0;
		}
		final why: String = result.reverted.length == 0 ? '' : ' (${result.reason})';
		return {
			tail: ', oracle-assisted: ${result.applied.length} file(s) applied, ${result.reverted.length}' + ' reverted to report-only$why',
			appliedCount: edits
		};
	}

	/**
	 * Why the oracle-assisted phase cannot run at all — an oracle that will not launch, or a tree
	 * that does not typecheck — as the summary TAIL to print (leading separator and all), or null
	 * when it may proceed.
	 *
	 * Same wording caveat as `verifyRiskyFixes` for the rejection: this verdict is taken AFTER the
	 * safe writes, so "baseline" would name the wrong thing. `reconcileSafePass` has already
	 * reverted a tree the safe pass broke, so a rejection here is a pre-existing one.
	 */
	private static function assistedSkipTail(oracleHxml: String, oracleDir: Null<String>): Null<String> {
		return switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
			case Confirmed: null;
			case Unavailable(reason): ', oracle-assisted skipped (oracle unavailable: $reason)';
			case Rejected(_): ', oracle-assisted skipped (the tree does not typecheck — see the note above)';
		};
	}

	/**
	 * Every annotation the oracle-assisted checks propose for ONE file, from findings already
	 * collected across the whole set. Empty when none of them has anything to say here.
	 */
	private static function assistedEdits(
		entry: { file: String, source: String }, findingsByCheck: Array<{ check: Check, all: Array<Violation> }>, plugin: GrammarPlugin,
		display: CompilerDisplayOracle
	): Array<{ span: Span, text: String }> {
		final out: Array<{ span: Span, text: String }> = [];
		for (byCheck in findingsByCheck) {
			final own: Array<Violation> = byCheck.all.filter(v -> v.file == entry.file);
			if (own.length == 0) continue;
			for (edit in (cast byCheck.check: OracleAssisted).fixWithOracle(entry.source, own, plugin, display)) out.push(edit);
		}
		return out;
	}

	/**
	 * Why `edits` do NOT all land where the oracle's compile actually TYPECHECKS `entry`, or
	 * null when they do — the sentence a decline quotes.
	 *
	 * Every edit's whole SPAN, because the file is written and verified as ONE candidate: a
	 * single annotation in a `#if` branch nothing compiles makes the verdict on the rest
	 * unattributable, and one that straddles such a branch does it with both its ends in live
	 * code.
	 */
	private static function assistedEditsAreVerifiable(
		compiled: OracleCoverage, entry: { file: String, source: String }, edits: Array<{ span: Span, text: String }>,
		plugin: GrammarPlugin
	): Null<String> {
		return compiled.uncovered(
			entry.file, entry.source, [for (edit in edits) edit.span], plugin.refShape(), plugin.lexicalRegions(entry.source)
		);
	}

	/**
	 * Write every candidate's annotated source, then typecheck FRESH and REVERT any file
	 * the compiler blames — retrying until the build is clean, unattributable, or a pass
	 * budget is spent. A file whose annotation breaks the build is restored to `before`
	 * (report-only); the rest are kept. Batch-then-error-guided-revert keeps the verify
	 * to a FEW full compiles instead of one per file — the throughput the per-file spec
	 * degrades to at scale (a local's annotation errors in its OWN file, so the compiler
	 * names the culprits precisely). A pass-budget or unverifiable outcome reverts ALL
	 * remaining, never keeping an unverified edit.
	 */
	public static function verifyOracleBatch(
		candidates: Array<{ file: String, before: String, after: String }>, oracleHxml: String, oracleDir: Null<String>,
		?typecheck: (String, Null<String>) -> OracleOutcome
	): OracleBatchResult {
		// The oracle arrives as a parameter for the same reason `TypeOracle` is an interface: the
		// three rollback CAUSES below are environment-shaped (a compiler that will not launch, an
		// error text naming no candidate, a batch that never settles) and a fixture cannot stage
		// them against a real haxe. A test supplies canned verdicts; production passes nothing.
		final verdict: (String, Null<String>) -> OracleOutcome = typecheck ?? (h, d) -> CompilerOracle.typecheck(h, d);
		CliIo.writeFiles([for (c in candidates) { path: c.file, content: c.after }]);
		final reverted: Array<String> = [];
		var confirmed: Bool = false;
		var reason: String = 'compiler rejected';
		var pass: Int = 0;
		final maxPasses: Int = 6;
		while (pass < maxPasses && !confirmed) {
			pass++;
			switch verdict(oracleHxml, oracleDir) {
				case Confirmed:
					confirmed = true;
				case Unavailable(_):
					reason = 'oracle unavailable';
					revertRemaining(candidates, reverted);
					break;
				case Rejected(errors):
					final culprits: Array<String> = oracleErrorFiles(errors, candidates, reverted);
					if (culprits.length == 0) {
						reason = 'compiler rejected, no file named';
						revertRemaining(candidates, reverted);
						break;
					}
					for (f in culprits) {
						for (c in candidates) if (c.file == f) CliIo.writeFile(c.file, c.before);
						reverted.push(f);
					}
			}
		}
		if (!confirmed) {
			if (pass >= maxPasses) reason = 'not converged in $maxPasses passes';
			revertRemaining(candidates, reverted);
		}
		final applied: Array<String> = [for (c in candidates) if (!reverted.contains(c.file)) c.file];
		return { applied: applied, reverted: reverted, reason: reason };
	}

	/**
	 * Put the in-memory sources back in step with what `verifyOracleBatch` WROTE.
	 *
	 * The oracle-assisted phase used to be the last thing that touched the tree, so nothing read
	 * `entry.source` afterwards and the drift was invisible. `followUpRound` reads it: an unsynced
	 * file is re-linted from its PRE-annotation bytes and written back over the verified edit, so
	 * the annotation is silently lost and the round is blind to this phase besides. Measured on a
	 * file taking both a risky `inline` and an oracle-assisted `:Int` — the `inline` survived, the
	 * return type did not, and `--fix` counted both. A REVERTED candidate is already back at
	 * `before` on disk, which is what `entry.source` still holds, so it is left alone.
	 */
	private static function syncAppliedSources(
		files: Array<{ file: String, source: String }>, candidates: Array<{ file: String, before: String, after: String }>,
		applied: Array<String>
	): Void {
		for (c in candidates) if (applied.contains(c.file)) for (entry in files) if (entry.file == c.file) entry.source = c.after;
	}

	/** Candidate files (not already reverted) the compiler error text blames — a local's bad annotation errors in its own file, so the error's `path:` names the culprit. */
	private static function oracleErrorFiles(
		errors: String, candidates: Array<{ file: String, before: String, after: String }>, reverted: Array<String>
	): Array<String> {
		final out: Array<String> = [];
		for (c in candidates) if (!reverted.contains(c.file) && !out.contains(c.file) && errorMentionsFile(errors, c.file))
			out.push(c.file);
		return out;
	}

	/** Whether any error line's leading `path:` token equals `full`, IS its basename, or ends with `/<basename>`. */
	private static function errorMentionsFile(errors: String, full: String): Bool {
		final base: String = Path.withoutDirectory(full);
		for (line in errors.split('\n')) {
			final colon: Int = line.indexOf(':');
			if (colon <= 0) continue;
			final path: String = StringTools.trim(line.substring(0, colon));
			if (path == full || path == base || path.endsWith('/$base')) return true;
		}
		return false;
	}

	/** Restore every not-yet-reverted candidate to its pre-annotation bytes and mark it reverted. */
	private static function revertRemaining(
		candidates: Array<{ file: String, before: String, after: String }>, reverted: Array<String>
	): Void {
		// Whole set through one `writeFiles`, for the same reason `reconcileSafePass.restore` uses
		// it: a rollback stopped half way leaves a tree carrying some unverified annotations and
		// not others, which is the state this function exists to leave behind under no
		// circumstances. Per-CULPRIT reverts above stay individual — those are incremental by
		// construction, one round per oracle verdict.
		final undo: Array<{ file: String, before: String, after: String }> = candidates.filter(c -> !reverted.contains(c.file));
		CliIo.writeFiles([for (c in undo) { path: c.file, content: c.before }]);
		for (c in undo) reverted.push(c.file);
	}

	/**
	 * The files of this run the grammar could not read. Every one was parsed during the lint pass
	 * just before, so these are cache hits rather than a second parse of the tree.
	 */
	public static function unparseableFiles(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<String> {
		return [
			for (entry in files) if (CheckScan.parseOrNull(plugin, entry.source) == null) entry.file
		];
	}

}
