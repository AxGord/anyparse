package anyparse.check;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

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

	/** Total EDITS that survived verification — the honest "issues fixed" contribution, unlike the FILE count. */
	var appliedEdits: Int;
	var reverted: Array<FixVerifyRevert>;
	var partials: Array<FixVerifyPartial>;
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
}

/**
 * Per (risky-check, file) detail for a file whose full edit set failed the oracle
 * and was BISECTED: `appliedEdits` survived (the safe complement was written),
 * `revertedEdits` were reverted — the isolated failer(s) plus, for a `GroupedFix`
 * check, every edit sharing their group — or all of them on a budget / confirm
 * fallback (`appliedEdits == 0`). Both stay EDIT counts even when the bisect worked
 * in GROUPS, so a reader never has to know whether the rule grouped anything.
 * `oracleInvocations` is the total compiler spawns spent verifying this file: the
 * initial full-set typecheck, the bisect probes, and the complement confirm. Emitted
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
 * rolled back (`Reverted`), or the set was bisected into a kept complement and a
 * reverted remainder (`Partial`, carrying the kept / reverted counts and the
 * oracle spawns spent). The caller folds these into the `FixVerifyResult` lists.
 */
private enum EntryVerdict {
	NoChange;
	Applied;
	Reverted;
	Partial(appliedEdits: Int, revertedEdits: Int, oracleInvocations: Int);
}

/**
 * Fix-verification for `RiskyFix` checks: the machinery behind the `compilerOracle`
 * key's promise that a rewrite/deletion is applied ONLY if it still compiles. It
 * assumes the safe (non-risky) fixes are already applied on disk, then for each
 * risky check and each file it applies that check's edits speculatively, writes the
 * candidate, runs the compiler oracle, and KEEPS it on `Confirmed` or reconciles
 * otherwise — the report-only fallback.
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
		oracleDir: Null<String>, write: (String, String) -> Void, ?optsByFile: Map<String, Null<String>>
	): FixVerifyResult {
		final applied: Array<String> = [];
		final reverted: Array<FixVerifyRevert> = [];
		final partials: Array<FixVerifyPartial> = [];
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
					partials: partials
				};
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
			// reification gate here. The oracle below cannot stand in for it — a risky rewrite inside
			// a `macro …` quotation still typechecks, so verification would pass it untouched.
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
				if (edits.length == 0) continue;
				final opts: Null<String> = optsByFile == null ? null : optsByFile[entry.file];
				switch verifyEntry(entry, edits, plugin, opts, oracleHxml, oracleDir, write) {
					case NoChange:
					case Applied:
						applied.push(entry.file);
						appliedEdits += edits.length;
					case Reverted:
						reverted.push({ file: entry.file, rule: check.id() });
					case Partial(keptEdits, revertedEdits, probes):
						appliedEdits += keptEdits;
						if (keptEdits > 0)
							applied.push(entry.file)
						else
							reverted.push({ file: entry.file, rule: check.id() });
						partials.push({
							file: entry.file,
							rule: check.id(),
							appliedEdits: keptEdits,
							revertedEdits: revertedEdits,
							oracleInvocations: probes
						});
				}
			}
		}
		return {
			baseline: baseline,
			applied: applied,
			appliedEdits: appliedEdits,
			reverted: reverted,
			partials: partials
		};
	}

	/**
	 * Speculatively apply `edits` to one file and reconcile with the oracle. The
	 * full set is written and typechecked first: `Confirmed` keeps it (`Applied`);
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
	 * Mutates `entry.source` and the disk (`write`) to the final decided text.
	 */
	private static function verifyEntry(
		entry: { file: String, source: String }, edits: Array<GroupedEdit>, plugin: GrammarPlugin, opts: Null<String>, oracleHxml: String,
		oracleDir: Null<String>, write: (String, String) -> Void
	): EntryVerdict {
		final before: String = entry.source;
		final full: Array<{ span: Span, text: String }> = [for (e in edits) { span: e.span, text: e.text }];
		final fullText: String = switch RefactorSupport.canonicalize(before, full, false, plugin, opts) {
			case Ok(text) if (text != before): text;
			case _: return NoChange;
		};
		write(entry.file, fullText);
		switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
			case Confirmed:
				entry.source = fullText;
				return Applied;
			case Unavailable(_):
				entry.source = before;
				write(entry.file, before);
				return Reverted;
			case Rejected(_):
		}
		final units: Array<Array<Int>> = unitsOf(edits);
		final n: Int = units.length;
		if (n < 2) {
			entry.source = before;
			write(entry.file, before);
			return Reverted;
		}
		// Cap all oracle spawns for this file at 2*ceil(log2(n)) + 2: the initial full-set
		// typecheck (already spent) + the bisect search + the confirm. The search gets the
		// middle 2*ceil(log2(n)) probes; a single failing UNIT needs at most that, so it
		// never spuriously falls back.
		final searchBudget: Int = 2 * ceilLog2(n);
		final spent: Array<Int> = [0];
		function probe(indices: Array<Int>): Bool {
			final subset: Array<{ span: Span, text: String }> = editsOfUnits(edits, units, indices);
			return switch RefactorSupport.canonicalize(before, subset, false, plugin, opts) {
				case Ok(text):
					write(entry.file, text);
					switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
						case Confirmed: true;
						case _: false;
					}
				case _: false;
			};
		}
		final failers: Null<Array<Int>> = isolateFailers(n, searchBudget, probe, spent);
		if (failers == null || failers.length >= n) {
			entry.source = before;
			write(entry.file, before);
			return Partial(0, edits.length, 1 + spent[0]);
		}
		final failerUnits: Array<Int> = failers;
		final keptUnits: Array<Int> = [for (u in 0...n) if (!failerUnits.contains(u)) u];
		final safe: Array<{ span: Span, text: String }> = editsOfUnits(edits, units, keptUnits);
		final invocations: Int = 1 + spent[0] + 1;
		return switch RefactorSupport.canonicalize(before, safe, false, plugin, opts) {
			case Ok(safeText) if (safeText != before):
				write(entry.file, safeText);
				switch CompilerOracle.typecheck(oracleHxml, oracleDir) {
					case Confirmed:
						entry.source = safeText;
						Partial(safe.length, edits.length - safe.length, invocations);
					case _:
						entry.source = before;
						write(entry.file, before);
						Partial(0, edits.length, invocations);
				}
			case _:
				entry.source = before;
				write(entry.file, before);
				Partial(0, edits.length, 1 + spent[0]);
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
private class BudgetExceeded extends haxe.Exception {

	public function new() {
		super('fix-verifier bisect budget exceeded');
	}

}
