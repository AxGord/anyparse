package anyparse.check;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.check.OracleCoverage;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of a risky-fix verification pass. `baseline` is the typecheck of the
 * trusted (safe-only) state BEFORE any risky edit — verification proceeds only
 * when it is `Confirmed`, so a compile failure is always attributable to the
 * risky edit rather than to pre-existing breakage. `applied` lists the files
 * whose risky edit survived the compile (fully OR partially — a partially-applied
 * file changed on disk and belongs here); `reverted` names the (file, rule) pairs
 * whose risky edits were all rolled back to report-only. `partials` carries per-file detail
 * for every file whose full edit set failed and was bisected (see below).
 */
typedef FixVerifyResult = {
	var baseline: OracleOutcome;
	var applied: Array<String>;

	/** Total EDITS that survived verification — this phase's contribution to the run summary's edit count, unlike the FILE count. */
	var appliedEdits: Int;
	var reverted: Array<FixVerifyRevert>;
	var partials: Array<FixVerifyPartial>;

	/**
	 * The (file, rule) pairs whose risky edits were never WRITTEN, because the configured
	 * oracle does not compile that file — see `FixVerifyDecline`. Kept apart from
	 * `reverted`: a revert is a candidate the compiler read and refused, a decline is a
	 * candidate no compiler would ever have read.
	 */
	var declined: Array<FixVerifyDecline>;

	/**
	 * Why the oracle's COMPILED SET could not be established, or null when it could. A
	 * non-null value means no risky fix was verified this run and every list above is
	 * empty — an oracle whose coverage is unknown proves nothing about any file.
	 */
	var coverageUnknown: Null<String>;

	/**
	 * The compiled-set probe this run PAID FOR, or null when it never needed one (no risky
	 * candidate ever existed, or the baseline was not `Confirmed`).
	 *
	 * Handed back so the caller's oracle-assisted phase can ask the same question without
	 * spawning a second `-v` compile — and, more to the point, so that it asks at all: it
	 * writes annotations and verifies them with the same typecheck, and was ungated.
	 */
	var coverage: Null<OracleCoverage>;

	/**
	 * What each risky check ACHIEVED, one row per (rule, file) it had findings in — see
	 * `FixVerifyTally`. The lists above answer per FILE and per EVENT, which is the wrong
	 * shape for the caller's per-RULE fix ledger, and so a `RiskyFix` rule used to add edits
	 * to the run's count and never a finding to the block that says what went unfixed.
	 */
	var tallies: Array<FixVerifyTally>;
}

/**
 * What ONE risky check achieved in ONE file: the findings it reported there, and the edits that
 * LANDED for them.
 *
 * The shape the caller's fix ledger is keyed by, and the reason it exists: `Cli`'s ledger is filled
 * by the safe loop alone, so with a `compilerOracle` configured the 13 `RiskyFix` rules contributed
 * EDITS to the run's summary count and never a FINDING to the per-rule block that says what got no
 * edit — the two numbers a reader compares were measured over two different rule sets.
 *
 * `edits == 0` is a decline, and WHY is in `reverted` / `declined` under the same (file, rule) pair
 * when the verifier has an answer; carrying that sentence a second time here would be a second copy
 * of `revertCauseText` in this package. It can legitimately be in NEITHER list — an edit set that
 * canonicalised back to the original source declines with nothing to quote. What never reaches a row
 * at all is `SourceNotCanonical`: that one is not the check's decline, it is the tree's formatting
 * state, and folding it in charged the rule for it.
 *
 * A row per FILE rather than per rule, because that is where the verdict is taken — a rule can be
 * applied in one file and reverted in the next, and one row per rule could state only one of them.
 */
typedef FixVerifyTally = {
	var rule: String;
	var file: String;

	/** Findings this check reported in this file — the `reported` half of a ledger row. */
	var findings: Int;

	/** Edits that survived to disk: the full set, the kept complement of a bisect, or 0. */
	var edits: Int;

	/**
	 * The sentences the CHECK ITSELF wrote onto the findings it declined in this file, one row
	 * per distinct sentence with the number of findings carrying it.
	 *
	 * CARRIED rather than looked up, unlike the verifier's own reason: `Violation.declineReason`
	 * is written onto the violation objects `verify` built HERE, through its own
	 * `Linter.collect`, and handed to `fix` — nothing outside this function can ever see them
	 * again. Until this field existed that channel was structurally dead for all 13 `RiskyFix`
	 * rules, and a check adding a reason changed no reported byte, which is how it stayed
	 * unnoticed: two checks were given reasons and both Pony ledgers came back byte-identical.
	 *
	 * The row count can be BELOW `findings`: a check speaks for the sites it declined and says
	 * nothing about the ones it fixed or silently skipped. The caller charges the remainder to
	 * the verifier's own answer, never these.
	 */
	var declineReasons: Array<{ text: String, count: Int }>;
}

/**
 * One rolled-back risky edit set: the FILE it targeted and the RULE that proposed it.
 *
 * The pair, not the count. A verifier that says only HOW MANY reverted leaves the reader with a
 * search rather than an answer — attributing three reverts on an 809-file tree took an md5 snapshot
 * of every file before and after a sweep, then eleven single-rule runs to name the rule, and STILL
 * left two of the three unattributed because they revert only when every rule runs together. The
 * rule id is already in hand at the moment of the revert (`verify` iterates the risky checks), so
 * carrying it costs nothing and turns that search into one line of output.
 *
 * A file appears once per RULE that reverted on it, which is the honest shape: two rules can each
 * propose a doomed edit set for the same file, and collapsing them would hide one.
 */
typedef FixVerifyRevert = {
	var file: String;
	var rule: String;

	/** Which of the two failures rolled it back — see `FixRevertCause`. */
	var cause: FixRevertCause;
}

/**
 * One risky edit set the verifier DECLINED without ever writing it: the FILE it
 * targeted, the RULE that proposed it, how many edits went unapplied, and the
 * coverage answer that refused them.
 *
 * A decline is not a revert, and the two must not be counted as one. A revert says
 * the compiler read a candidate and rejected it — the verdict a `compilerOracle`
 * exists to give. A decline says the compiler never reads this file at all, so no
 * candidate for it could ever have failed: an exit-0 typecheck after writing it is
 * a control that cannot fire, and the run has nothing to report but that.
 */
typedef FixVerifyDecline = {
	var file: String;
	var rule: String;
	var edits: Int;

	/** Why the oracle could say nothing about this file — ready for the summary line. */
	var reason: String;
}

/**
 * WHY a risky edit set was rolled back, and the whole point is that these are
 * NOT the same event.
 *
 * `OracleRejected` is the verdict a `compilerOracle` exists to give: a candidate
 * was written, the compiler read it, and it did not build. `NotCanonical` says
 * no candidate ever reached the compiler — the writer refused to canonicalise
 * the spliced source, so nothing was typechecked and nothing about the check's
 * edit was learned. `OracleUnavailable` is the third: the oracle could not run
 * at all.
 *
 * They were one answer until now, because every non-`Ok` from
 * `RefactorSupport.canonicalize` fell into a `case _: false` that the bisect
 * reads as "the compiler said no". Since `canonicalize` began refusing a source
 * the writer cannot settle on a fixed point, that arm carries a WRITER defect
 * wearing the compiler's name — and a reader chasing the recorded reason goes
 * looking in the check's edit for a type error that is not there.
 */
enum FixRevertCause {

	/** The candidate was written and the compiler rejected it. */
	OracleRejected;

	/** The oracle could not run; `reason` is its own diagnostic. */
	OracleUnavailable(reason: String);

	/** No candidate was produced: `RefactorSupport.canonicalize` refused with `message`. */
	NotCanonical(message: String);

}

/**
 * Per (risky-check, file) detail for a file whose full edit set failed the oracle
 * and was BISECTED: `appliedEdits` survived (the safe complement was written),
 * `revertedEdits` were reverted — the isolated failer(s) plus, for a `GroupedFix`
 * check, every edit sharing their group — or all of them on a budget / confirm
 * fallback (`appliedEdits == 0`). Both stay EDIT counts even when the bisect worked
 * in GROUPS, so a reader never has to know whether the rule grouped anything.
 * `oracleInvocations` is the total compiler SPAWNS spent verifying this
 * file: the initial full-set typecheck, the bisect probes that produced a
 * candidate, and the complement confirm when one ran. A probe the writer REFUSED never
 * reached a compiler and is not counted — it still costs the search BUDGET,
 * which is a different quantity and the one `spent` carries. Emitted
 * only for the bisect path; a fully-applied file or a single-unit file carries no
 * entry.
 */
typedef FixVerifyPartial = {
	var file: String;
	var rule: String;
	var appliedEdits: Int;
	var revertedEdits: Int;
	var oracleInvocations: Int;
}

/**
 * The verdict `verifyEntry` returns for one (check, file) edit set: nothing
 * happened (`NoChange`), the whole set survived (`Applied`), the whole set was
 * rolled back (`Reverted`, carrying WHY), or the set was bisected into a kept complement and a reverted remainder (`Partial`, carrying
 * the kept / reverted counts, the oracle spawns spent, and why). The caller folds these into the `FixVerifyResult` lists.
 */
private enum EntryVerdict {
	NoChange;

	/**
	 * No candidate was produced because the SOURCE is not the writer's fixed point, so
	 * nothing was spliced and nothing whatever was learned about this check.
	 *
	 * Apart from `NoChange` because the caller's fix ledger must not read it as a decline. A
	 * decline is a fact about the RULE; this is a fact about the tree's formatting, on which
	 * the rule has no opinion — and on a tree nobody has run `fmt` over it is the common
	 * answer, not the exceptional one. Folded in as a decline it printed `its fix was called
	 * for these findings and returned no edit` against a check that was never asked.
	 */
	SourceNotCanonical;
	Applied;

	/**
	 * A candidate WAS produced and then not written, because no typecheck could have
	 * judged it: `reason` says whether the FILE sits outside the oracle's compiled set or
	 * the REGION the edits land in is a conditional branch no compiled arm makes live.
	 * Reached only after the canonicalise, which is what keeps the reported count honest —
	 * a rule whose edits the writer would have refused anyway is `NoChange`, not a decline.
	 */
	Declined(reason: String);
	Reverted(cause: FixRevertCause);
	Partial(appliedEdits: Int, revertedEdits: Int, oracleInvocations: Int, cause: FixRevertCause);
}

/**
 * Fix-verification for `RiskyFix` checks: the machinery behind the `compilerOracle`
 * key's promise that a rewrite/deletion is applied ONLY if it still compiles. It
 * assumes the safe (non-risky) fixes are already applied on disk, then for each
 * risky check and each file it applies that check's edits speculatively, writes the
 * candidate, runs the compiler oracle, and KEEPS it on `Confirmed` or reconciles
 * otherwise — the report-only fallback.
 *
 * That promise carries a precondition the oracle cannot state for itself: the file
 * must be one the hxml actually COMPILES. An hxml routinely compiles a subset of the
 * tree a lint run walks, and for a file outside it the post-write typecheck cannot
 * fail whatever the edit did. So `verify` asks `OracleCoverage` before it writes
 * anything, and DECLINES an edit set whose file the oracle never reads
 * (`FixVerifyDecline`) instead of spending a compile to obtain a green verdict no edit
 * could have turned red. An oracle whose compiled set cannot be established at all
 * stops the phase outright (`coverageUnknown`).
 *
 * Rollback granularity is PER-EDIT by default, and per-GROUP for a check that opts
 * into `GroupedFix`: when the full set fails, the edits are bisected
 * (`isolateFailers` — binary-split group testing) so one unsafe edit among N no
 * longer reverts the safe others. The bisect walks UNITS rather than raw edits —
 * one unit per ungrouped edit, one per group — so edits a check declared
 * inseparable (an `import` and the rewrites that need it) are kept or dropped
 * WHOLE, and a probe can no longer strand half of them. `N` in the budget below is
 * therefore the UNIT count; with no grouping every unit is a singleton, and the
 * arithmetic, the probe sequence and the reported counts are what they always were.
 * Each probe re-canonicalises from the ORIGINAL source with a subset (spans are
 * original-source-relative, never stacked onto already-edited text); the isolated
 * safe complement is confirm-typechecked and written, only the failer(s) revert.
 * Oracle spawns per file are capped at `2*ceil(log2(N)) + 2` (the initial
 * typecheck + the bisect search + the confirm); beyond the cap the file falls back
 * to a whole-file revert. Cross-file risky checks are out of scope — the intended
 * consumers (avoid-dynamic / prefer-inline and other targeted rewrites) are
 * single-file.
 *
 * Stateless and free of global mutable state (the invariant): all state is the
 * caller's `files`/disk plus locals; `write` is the caller's own file sink so the
 * verifier does no IO of its own beyond the oracle spawn.
 */
@:nullSafety(Strict)
final class FixVerifier {

	public static function verify(
		files: Array<{ file: String, source: String }>, riskyChecks: Array<Check>, plugin: GrammarPlugin, oracleHxml: String,
		oracleDir: Null<String>, write: (String, String) -> Void, ?optsByFile: Map<String, Null<String>>, ?coverage: OracleCoverage
	): FixVerifyResult {
		final applied: Array<String> = [];
		final reverted: Array<FixVerifyRevert> = [];
		final partials: Array<FixVerifyPartial> = [];
		final declined: Array<FixVerifyDecline> = [];
		// One row per (rule, file) the check reported in, filled at every exit from the
		// per-entry switch below — including the `continue` for a check that answered no edit
		// at all, which is a decline like any other and the one the caller could least see.
		final tallies: Array<FixVerifyTally> = [];
		var appliedEdits: Int = 0;
		final baseline: OracleOutcome = CompilerOracle.typecheck(oracleHxml, oracleDir);
		switch baseline {
			case Confirmed:
			case Rejected(_), Unavailable(_):
				return {
					baseline: baseline,
					applied: applied,
					appliedEdits: appliedEdits,
					reverted: reverted,
					partials: partials,
					declined: declined,
					coverageUnknown: null,
					coverage: null,
					tallies: tallies
				};
		}
		// LAZY on purpose: the probe is a compile, and a run whose risky checks find nothing
		// must not pay for one. It is asked the moment the FIRST candidate edit set exists,
		// which is also the first moment an answer could matter.
		//
		// One probe per RUN, so MEMBERSHIP is a snapshot even though knownness is not: a fix
		// that removes the last reference to a module can drop it out of the compiled set
		// afterwards, and a later candidate there would then be judged by a compile that no
		// longer reads it. The common direction is the safe one — a fix that ADDS a reference
		// only leaves the snapshot conservative — and re-probing per file would cost one
		// compile each, which is the whole expense this gate exists to avoid.
		var coverageMemo: Null<OracleCoverage> = coverage;
		function compiledSet(): OracleCoverage {
			final memo: Null<OracleCoverage> = coverageMemo;
			if (memo != null) return memo;
			final probed: OracleCoverage = OracleCoverage.probe(oracleHxml, oracleDir);
			coverageMemo = probed;
			return probed;
		}
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		// One WHOLE-SET run per check, findings then grouped per file: a risky check's
		// soundness gates can be whole-project (prefer-inline's subtype-override /
		// value-reference scans), and a per-file run starves them — the safe loop routes
		// such rules through `fullScopeIds` (`Cli.applyLintFixes`), and the oracle cannot
		// compensate when the vetoing declaration (a test-tree subtype, in the motivating
		// incident) is outside the hxml's compiled set. A finding for entry k is computed
		// before entries < k had their fixes applied — harmless while risky fixes are
		// same-file insertions.
		for (check in riskyChecks) {
			// Through `Linter.collect`, never `check.run` directly: that is what applies the central
			// reification and inline-suppression gates here. The oracle below cannot stand in for
			// either — a risky rewrite inside a `macro …` quotation still typechecks, and so does one
			// on a line whose `// noqa` says the rule is wrong there.
			final all: Array<Violation> = Linter.collect(files, plugin, [check]).filter(v -> v.rule == check.id());
			for (entry in files) {
				final own: Array<Violation> = all.filter(v -> v.file == entry.file);
				if (own.length == 0) continue;
				// A GROUPED check names which of its edits are inseparable — an `import` and the
				// rewrites that need it. Every other check keeps the flat contract, and the
				// all-null group array it yields bisects per edit exactly as it did before.
				final edits: Array<GroupedEdit> = check is GroupedFix
					? (cast check: GroupedFix).fixGrouped(entry.source, own, plugin, index)
					: [
						for (e in check.fix(entry.source, own, plugin, index)) { span: e.span, text: e.text, group: null }
					];
				if (edits.length == 0) {
					// The check was asked for these findings and answered nothing — a decline, and
					// the only one no other list in this result records.
					tallies.push({
						rule: check.id(),
						file: entry.file,
						findings: own.length,
						edits: 0,
						declineReasons: checkReasons(own)
					});
					continue;
				}
				// The coverage question, asked BEFORE anything is written. `compiledSet` memoises,
				// so its knownness cannot change mid-loop: an unknown answer is therefore always the
				// first one, and returning here can never abandon an already-applied candidate.
				final compiled: OracleCoverage = compiledSet();
				if (!compiled.known) return {
					baseline: baseline,
					applied: applied,
					appliedEdits: appliedEdits,
					reverted: reverted,
					partials: partials,
					declined: declined,
					coverageUnknown: compiled.reason,
					coverage: compiled,
					// Emptied to keep the contract `coverageUnknown` states: every list above is
					// empty here, because an oracle whose compiled set cannot be established proves
					// nothing about any file. The rows a check produced before the unknown answer
					// arrived are the only ones that could be non-empty, and a partial ledger reads
					// as "these rules declined here" about a phase that stopped. The caller gates on
					// `coverageUnknown` and never folds these, so this is the value agreeing with
					// the contract rather than a second gate.
					tallies: []
				};
				final opts: Null<String> = optsByFile == null ? null : optsByFile[entry.file];
				// The verdict answers HOW MANY of this check's edits reached disk, because that
				// is the one thing the caller's ledger row turns on: zero is a decline whatever
				// the reason, and the reason is already in `declined` / `reverted` under the same
				// (file, rule) pair.
				final verdict: EntryVerdict = verifyEntry(entry, edits, plugin, opts, oracleHxml, oracleDir, write, compiled);
				final landed: Int = switch verdict {
					case NoChange, SourceNotCanonical: 0;
					case Declined(reason):
						// The whole point of this class: code the oracle never typechecks cannot be
						// typechecked into safety. Writing the candidate would spend a full compile to
						// obtain an exit 0 that no edit could have changed, and then report it as
						// `verified`. Say which file, which rule, and how much went unapplied instead.
						declined.push({
							file: entry.file,
							rule: check.id(),
							edits: edits.length,
							reason: reason
						});
						0;
					case Applied:
						applied.push(entry.file);
						appliedEdits += edits.length;
						edits.length;
					case Reverted(cause):
						reverted.push({
							file: entry.file,
							rule: check.id(),
							cause: cause
						});
						0;
					case Partial(keptEdits, revertedEdits, probes, cause):
						appliedEdits += keptEdits;
						if (keptEdits > 0)
							applied.push(entry.file)
						else
							reverted.push({
								file: entry.file,
								rule: check.id(),
								cause: cause
							});
						partials.push({
							file: entry.file,
							rule: check.id(),
							appliedEdits: keptEdits,
							revertedEdits: revertedEdits,
							oracleInvocations: probes
						});
						keptEdits;
				};
				// NOT for `SourceNotCanonical`. Every other verdict is something the check
				// answered — a candidate applied, reverted, declined, or an edit set that
				// changed nothing — and a row with `edits == 0` is read downstream as a
				// decline. That one is the tree's formatting state, on which the check was
				// never asked, and folding it in charged the rule for it.
				if (!verdict.match(SourceNotCanonical)) tallies.push({
					rule: check.id(),
					file: entry.file,
					findings: own.length,
					edits: landed,
					declineReasons: checkReasons(own)
				});
			}
		}
		return {
			baseline: baseline,
			applied: applied,
			appliedEdits: appliedEdits,
			reverted: reverted,
			partials: partials,
			declined: declined,
			coverageUnknown: null,
			coverage: coverageMemo,
			tallies: tallies
		};
	}

	/**
	 * The decline sentences `own`'s findings carry IN THE CHECK'S OWN WORDS, one row per distinct
	 * sentence with the number of findings carrying it.
	 *
	 * Read AFTER `fix` has been called, because that is the second of the two places a check writes
	 * one: `run` sets it when a whole-scope gate closes before any edit is computed, `fix` when the
	 * gate is per-site — and `fix` is handed these very objects. Reading it earlier would see only
	 * half the channel.
	 *
	 * Aggregated here rather than shipped raw so a 470-finding file costs one row per sentence, and
	 * so the caller folds it with the same `{text, count}` shape its own reason list already uses.
	 */
	private static function checkReasons(own: Array<Violation>): Array<{ text: String, count: Int }> {
		// First-appearance order, kept explicitly: the caller folds these into a list the reporter
		// SORTS by count, but a stable order still makes a fixture assertable.
		final order: Array<String> = [];
		final counts: Map<String, Int> = [];
		for (violation in own) {
			final reason: Null<String> = violation.declineReason;
			if (reason == null) continue;
			final seen: Null<Int> = counts[reason];
			if (seen == null) order.push(reason);
			counts[reason] = (seen ?? 0) + 1;
		}
		return [for (text in order) { text: text, count: counts[text] ?? 0 }];
	}

	/**
	 * Speculatively apply `edits` to one file and reconcile with the oracle.
	 *
	 * A candidate the oracle does not TYPECHECK — its file outside the compiled set, or its
	 * edits inside a conditional branch no compiled arm makes live — is `Declined` the moment
	 * it exists, carrying which of the two it was; asked after the canonicalise so the verdict
	 * distinguishes "no candidate" from "a candidate nothing can judge".
	 *
	 * Otherwise the full set is written and typechecked first:
	 * `Confirmed` keeps it (`Applied`);
	 * `Unavailable` (the oracle cannot run) or a `Rejected` with fewer than two
	 * UNITS reverts the whole file (`Reverted`). A multi-unit `Rejected` is
	 * BISECTED — `isolateFailers` isolates the failing UNITS by binary search (each
	 * probe re-canonicalises from the ORIGINAL `before` with that subset's edits),
	 * the safe complement is confirm-typechecked and written, and only the failing
	 * units revert (`Partial`).
	 *
	 * A UNIT is one edit, unless the check implements `GroupedFix` and tied several
	 * edits into one group — `unitsOf` is the whole of the difference, and an
	 * ungrouped edit set makes every unit a singleton, i.e. exactly the per-edit
	 * bisect this always did. The `Partial` counts stay EDIT counts either way.
	 *
	 * A budget overrun or an unexpectedly-failing complement falls back to a
	 * whole-file revert, still reported as `Partial` with `appliedEdits == 0`.
	 *
	 * A probe whose subset the WRITER refused counts as a failing subset — that is
	 * the honest answer to "can this subset be applied and still build?" — and the
	 * search runs on. The refusal decides the reported cause at exactly one seat: the
	 * budget/blame-everything exit, which reaches no complement. Every later seat saw
	 * a complement of its own and answers from that.
	 *
	 * Mutates `entry.source` and the disk (`write`) to the final decided text.
	 */
	private static function verifyEntry(
		entry: { file: String, source: String }, edits: Array<GroupedEdit>, plugin: GrammarPlugin, opts: Null<String>, oracleHxml: String,
		oracleDir: Null<String>, write: (String, String) -> Void, coverage: OracleCoverage
	): EntryVerdict {
		final before: String = entry.source;
		final full: Array<{ span: Span, text: String }> = [for (e in edits) { span: e.span, text: e.text }];
		// Three outcomes, not two: an `Err` here is the WRITER declining the spliced
		// source, which is not the same event as a check that proposed nothing — and
		// `case _: return NoChange` recorded both as the latter, so a refused edit set
		// left no trace at all.
		//
		// But only ONE of the two `Err` origins belongs to this check. With
		// `reformat = false`, `canonicalize` first REFUSES a source that is not already
		// the writer's fixed point: nothing was spliced, nothing was learned, and on a
		// tree nobody has formatted that is the common case, not the exceptional one.
		// Charging the check for the TREE's state would put a `risky-fix REVERTED` line
		// and a +1 on the reverted count under every risky rule on every drifted file.
		// Re-asking the gate costs one round trip on an error path that is rare.
		final fullText: String = switch RefactorSupport.canonicalize(before, full, false, plugin, opts) {
			case Ok(text) if (text != before): text;
			case Ok(_): return NoChange;
			case Err(message): return RefactorSupport.isWriterCanonical(before, plugin, opts)
				? Reverted(NotCanonical(message))
				: SourceNotCanonical;
		};
		// The candidate exists; whether anything could ever JUDGE it is a separate question,
		// and it is asked here rather than earlier so that the decline count means what it says:
		// an edit set the writer would have refused is `NoChange` above, never a decline.
		// EVERY edit's whole span, because the set is written and judged as ONE candidate: one edit
		// landing where nothing is compiled makes the verdict on the rest unattributable, and a
		// single edit STRADDLING such a region is the same thing with both its ends in live code.
		final gap: Null<String> = coverage.uncovered(
			entry.file, before, [for (edit in edits) edit.span], plugin.refShape(), plugin.lexicalRegions(before)
		);
		if (gap != null) return Declined(gap);
		write(entry.file, fullText);
		switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
			case Confirmed:
				entry.source = fullText;
				return Applied;
			case Unavailable(reason):
				entry.source = before;
				write(entry.file, before);
				return Reverted(OracleUnavailable(reason));
			case Rejected(_):
		}
		final units: Array<Array<Int>> = unitsOf(edits);
		final n: Int = units.length;
		if (n < 2) {
			entry.source = before;
			write(entry.file, before);
			return Reverted(OracleRejected);
		}
		// Cap all oracle spawns for this file at 2*ceil(log2(n)) + 2: the initial full-set
		// typecheck (already spent) + the bisect search + the confirm. The search gets the
		// middle 2*ceil(log2(n)) probes; a single failing UNIT needs at most that, so it
		// never spuriously falls back.
		final searchBudget: Int = 2 * ceilLog2(n);
		final spent: Array<Int> = [0];
		// SPAWNS, not probes. `spent` is the BUDGET counter and every attempt costs one,
		// including a probe the writer refused before any compiler ran — so reporting it as
		// `oracleInvocations` overstated the compiler spawns this file cost, and the summary
		// line that prints it says "oracle run(s)" in so many words. Measured on a four-edit
		// set with two refusing probes: 5 reported against 3 real spawns.
		final spawns: Array<Int> = [0];
		// `isolateFailers` reads a BOOLEAN oracle, and a probe that could not build a
		// candidate still has an honest answer for the question the bisect asks — "can this
		// subset be applied and still build?" — which is no. So it counts as a failure and
		// the search CONTINUES: the complement it settles on is confirm-typechecked before
		// anything is KEPT (a probe writes its candidate to disk to typecheck it — every
		// exit below then writes back either `before` or a confirmed text), so a
		// mis-attributed unit can cost applied edits and never correctness. Abandoning here
		// instead cost the whole file: measured on a four-edit set whose complement the
		// compiler then CONFIRMED, the abandon applied 0 of 4 edits where the search applies
		// 2. What the refusal is kept for is the REPORTED cause at the ONE seat that reaches
		// no complement — see below.
		var uncanonical: Null<String> = null;
		function probe(indices: Array<Int>): Bool {
			final subset: Array<{ span: Span, text: String }> = editsOfUnits(edits, units, indices);
			return switch RefactorSupport.canonicalize(before, subset, false, plugin, opts) {
				case Ok(text):
					write(entry.file, text);
					spawns[0]++;
					switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
						case Confirmed: true;
						case _: false;
					}
				case Err(message):
					if (uncanonical == null) uncanonical = message;
					false;
			};
		}
		final failers: Null<Array<Int>> = isolateFailers(n, searchBudget, probe, spent);
		final refusal: Null<String> = uncanonical;
		// The full-set typecheck plus every probe that produced a candidate — stated once
		// because the whole point of the fix that introduced `spawns` is that this number is
		// exact. The confirm adds its own `+ 1`, at the one seat where it ran.
		final spawnsWithFullSet: Int = 1 + spawns[0];
		if (failers == null || failers.length >= n) {
			entry.source = before;
			write(entry.file, before);
			// The ONE seat where a refusal decides the cause, and the seat the abandoned bisect
			// used to reach directly: no complement was ever built, so nothing here was
			// compiler-judged and `NotCanonical` names the writer honestly. Every seat BELOW
			// knows more than this one and must answer from what IT saw — a hoisted cause put
			// `NotCanonical` on a complement the compiler had read and rejected, which is the
			// mirror of the defect the split of `FixRevertCause` exists to prevent.
			return Partial(0, edits.length, spawnsWithFullSet, refusal == null ? OracleRejected : NotCanonical(refusal));
		}
		final failerUnits: Array<Int> = failers;
		final keptUnits: Array<Int> = [for (u in 0...n) if (!failerUnits.contains(u)) u];
		final safe: Array<{ span: Span, text: String }> = editsOfUnits(edits, units, keptUnits);
		final invocations: Int = spawnsWithFullSet + 1;
		return switch RefactorSupport.canonicalize(before, safe, false, plugin, opts) {
			case Ok(safeText) if (safeText != before):
				write(entry.file, safeText);
				switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
					case Confirmed:
						entry.source = safeText;
						// `OracleRejected` explicitly, not by defaulting: the cause is REQUIRED so
						// that a future `Partial` cannot silently claim the compiler refused
						// something it never saw. Here it is the truth — the full set was
						// compiler-rejected, which is how the bisect was reached at all.
						Partial(safe.length, edits.length - safe.length, invocations, OracleRejected);
					case _:
						entry.source = before;
						write(entry.file, before);
						// The compiler READ this complement and refused it — `OracleRejected` whatever
						// happened earlier in the search. A refusal upstream says nothing about a
						// candidate the compiler judged for itself.
						Partial(0, edits.length, invocations, OracleRejected);
				}
			case Ok(_):
				entry.source = before;
				write(entry.file, before);
				// The complement canonicalises back to the input, so nothing new was judged — but
				// the FULL SET was, and its rejection is what put us here.
				Partial(0, edits.length, spawnsWithFullSet, OracleRejected);
			case Err(message):
				entry.source = before;
				write(entry.file, before);
				Partial(0, edits.length, spawnsWithFullSet, NotCanonical(message));
		};
	}

	/**
	 * The bisect's UNITS: one per distinct non-null `group`, in FIRST-APPEARANCE order,
	 * plus a singleton for every ungrouped edit at its own position. Each unit is the
	 * ascending edit indices it holds, and the bisect keeps or drops a unit WHOLE — which
	 * is what makes an `import` and the rewrites depending on it inseparable. An all-null
	 * input yields `[[0], [1], ...]`, so a check that does not implement `GroupedFix` is
	 * bisected per edit byte-for-byte as before.
	 */
	private static function unitsOf(edits: Array<GroupedEdit>): Array<Array<Int>> {
		final units: Array<Array<Int>> = [];
		final byGroup: Map<Int, Array<Int>> = [];
		for (i in 0...edits.length) {
			final group: Null<Int> = edits[i].group;
			if (group == null) {
				units.push([i]);
				continue;
			}
			final unit: Null<Array<Int>> = byGroup[group];
			if (unit == null) {
				final fresh: Array<Int> = [i];
				byGroup[group] = fresh;
				units.push(fresh);
			} else
				unit.push(i);
		}
		return units;
	}

	/**
	 * The plain `{span, text}` edits held by the UNITS `unitIndices` names, in ascending
	 * EDIT order — which is exactly what the ungrouped path produced before, and what keeps
	 * the splice reproducible: `RefactorSupport.applyEdits` orders by DESCENDING
	 * `span.from`, so two edits sharing a `from` (two zero-width insertions at one anchor)
	 * still resolve by input order.
	 */
	private static function editsOfUnits(
		edits: Array<GroupedEdit>, units: Array<Array<Int>>, unitIndices: Array<Int>
	): Array<{ span: Span, text: String }> {
		final flat: Array<Int> = [for (u in unitIndices) for (i in units[u]) i];
		flat.sort((a, b) -> a - b);
		return [for (i in flat) { span: edits[i].span, text: edits[i].text }];
	}

	/**
	 * Isolate the failing UNIT indices among `[0, count)` by binary-split group
	 * testing. A unit is one edit, or one `GroupedFix` group — the search is
	 * index-agnostic either way, `verifyEntry` owns the mapping (`unitsOf`).
	 * `probe(indices)` is true when that SUBSET (canonicalised from the ORIGINAL
	 * source with exactly those units' edits) typechecks. Precondition: the FULL set
	 * is known to fail, so no probe re-establishes it. Returns the sorted failer
	 * indices whose removal makes the complement pass, or null when the probe budget
	 * is exhausted (the caller falls back to a whole-file revert). `spent[0]` receives
	 * the probe count.
	 */
	private static function isolateFailers(count: Int, budget: Int, probe: Array<Int> -> Bool, spent: Array<Int>): Null<Array<Int>> {
		spent[0] = 0;
		return try bisectRec([for (i in 0...count) i], probe, budget, spent) catch (_: BudgetExceeded) null;
	}

	/**
	 * Recurse over a KNOWN-FAILING index block. A singleton is the failer. Otherwise
	 * split in half and probe each: recurse into a failing half, keep a passing one.
	 * When BOTH halves pass alone yet the block fails, the failure is a cross-half
	 * interaction (e.g. a failing pair straddling the split) — keep the passing left
	 * half and treat the right as the failers; the caller's confirm validates the
	 * whole complement.
	 */
	private static function bisectRec(indices: Array<Int>, probe: Array<Int> -> Bool, budget: Int, spent: Array<Int>): Array<Int> {
		if (indices.length <= 1) return indices;
		final mid: Int = indices.length >> 1;
		final left: Array<Int> = indices.slice(0, mid);
		final right: Array<Int> = indices.slice(mid);
		final leftPasses: Bool = countedProbe(left, probe, budget, spent);
		final rightPasses: Bool = countedProbe(right, probe, budget, spent);
		if (leftPasses && rightPasses) return right.copy();
		final failers: Array<Int> = [];
		if (!leftPasses) for (i in bisectRec(left, probe, budget, spent)) failers.push(i);
		if (!rightPasses) for (i in bisectRec(right, probe, budget, spent)) failers.push(i);
		return failers;
	}

	/** One budget-guarded probe; the call that would exceed `budget` throws `BudgetExceeded`. */
	private static function countedProbe(indices: Array<Int>, probe: Array<Int> -> Bool, budget: Int, spent: Array<Int>): Bool {
		if (spent[0] >= budget) throw new BudgetExceeded();
		spent[0]++;
		return probe(indices);
	}

	/** Smallest `k` with `2^k >= n` (the integer ceil of log2), for `n >= 1`. */
	private static function ceilLog2(n: Int): Int {
		var k: Int = 0;
		var v: Int = 1;
		while (v < n) {
			v <<= 1;
			k++;
		}
		return k;
	}

}

/** Internal control-flow signal: the bisect probe budget was exhausted. */
private class BudgetExceeded extends Exception {

	public function new() {
		super('fix-verifier bisect budget exceeded');
	}

}
