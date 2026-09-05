package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.CompilerOracle;
import anyparse.check.DefiniteAssignmentGuard;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.CanonicalEdit;
import anyparse.query.Cli.RuleEdits;
import anyparse.query.Cli.RuleFixOutcome;
import anyparse.query.LintFixSafePass;
import anyparse.query.cli.command.LintCommand.CheckPartition;
import anyparse.query.cli.command.LintFixVerify.RiskyFixOutcome;
import anyparse.runtime.Span;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * The outcome of one `lint --fix` pass over the active file set: `nextActive` is the file set (with rewritten sources) to feed the next fixpoint pass, and `fixedDelta` how many findings that pass resolved.
 */
typedef LintPassResult = {
	var nextActive: Array<{ file: String, source: String }>;
	var fixedDelta: Int;
};

/**
 * The pass loop behind `apq lint --fix`.
 *
 * A fix run is not one rewrite: it is a pass over the reported violations, a
 * safe / risky partition, a per-file edit ledger, and a follow-up round for what
 * the first pass unblocked. `LintCommand` owns the report; this owns the loop
 * that changes files, `LintFixVerify` the oracle that judges a risky batch, and
 * `LintFixLedger` the account of what was NOT fixed.
 */
@:nullSafety(Strict)
final class LintFixDriver {

	/**
	 * Cap on the per-file DECLINE lines a `--fix` phase prints. A decline is the common case
	 * on a partially-covered tree (483 of 679 files on the tree that motivated the gate), not
	 * the rare one a revert is, so an uncapped list buries the summary it belongs to.
	 */
	public static inline final DECLINE_LINES_SHOWN: Int = 20;

	/** How many rule ids `unfixedFixLedger` names before it summarises the rest as a count. */
	public static inline final DECLINED_RULES_SHOWN: Int = 6;

	/**
	 * How many distinct decline reasons ONE rule's row spells out before it summarises the rest.
	 * Smaller than the rule cap on purpose: a reason is a full sentence, and the row it hangs
	 * under is already the answer to "which rule" — three is the whole of every real case measured
	 * (`unused-import`'s four arms are the widest, and the fourth is 15 of 204 findings).
	 */
	public static inline final DECLINED_REASONS_SHOWN: Int = 3;

	private static function applyLintFixes(
		files: Array<{ file: String, source: String }>, checks: Array<Check>, plugin: GrammarPlugin, resolveConfig: (String) -> LintConfig,
		applyEnablement: Bool, ?resolution: ResolutionScope, ?oracleHxml: String, ?oracleDir: String
	): Int {
		final oracleConfigured: Bool = oracleHxml != null;
		final split: CheckPartition = LintCommand.partitionChecks(checks, oracleConfigured);
		for (c in split.risky) if (c is OracleRelaxable) (cast c: OracleRelaxable).setOracleRelaxed(true);
		final maxPasses: Int = 10;
		// Parse each file once and reuse the tree across the SymbolIndex build, every
		// check, and every fix — keyed by source content, so an unchanged file is
		// reused across passes and only a rewritten one re-parses on its new content.
		final cached: CachingGrammarPlugin = LintCommand.wrapResolution(plugin, resolution);
		// hxformat.json is on disk and source-independent — discover once per file.
		final optsByFile: Map<String, Null<String>> = [];
		for (entry in files) optsByFile[entry.file] = CliArgs.discoverFormatConfig(entry.file);

		// The pre-fix bytes of every file, kept so a safe pass that breaks a build which
		// was GREEN can be undone. The passes mutate `entry.source` in place and only the
		// single write loop below touches disk, so this one snapshot covers the whole run.
		final originalOf: Map<String, String> = [];
		for (entry in files) originalOf[entry.file] = entry.source;
		// Files eligible next pass: pass 1 = all; later passes = only the ones a
		// prior pass changed (a same-file fix exposes findings only where it edited; a cross-file fix would need a re-run).
		var active: Array<{ file: String, source: String }> = files.copy();
		final noted: Array<String> = [];
		// SEPARATE from `noted`, which the summary counts as `N file(s) skipped`: a file that
		// merely tripped the writer-rewrites note was fixed, not skipped, and sharing the set
		// would inflate that count the first time the note ever fires.
		final notedRewrites: Array<String> = [];
		final changedFiles: Array<String> = [];
		// File sets a cross-file fix committed as ONE unit — the safe-pass revert reverts them
		// whole or not at all (`LintFixSafePass.implicated`).
		final coupled: Array<Array<String>> = [];
		var fixedCount: Int = 0;
		var passes: Int = 0;
		var hitCap: Bool = false;
		// What each rule's fix DID this run — the measurement that replaces the guess
		// `fixed N issue(s)` used to leave the reader to make.
		final ledger: Map<String, RuleFixOutcome> = [];

		// The safe fixed-point loop, as a closure, because it runs TWICE: the risky and
		// oracle-assisted phases below write AFTER it has finished, so without a second round
		// every finding their edits EXPOSE is left standing by the very run that created it.
		// The motivating pair: `prefer-inline` marks a method `inline` (risky, oracle-verified),
		// which moves that method under `member-order`'s within-rank sub-order (inline leads its
		// rank) — and the loop that would have re-sorted it had already converged. `--fix` then
		// reported success while leaving a finding it had just introduced, and a second invocation
		// of the identical command fixed it. Four workers read that as two checks demanding an
		// impossible arrangement; it is one missing round. Each round gets its OWN `maxPasses`
		// budget: sharing one would let a tree that spends the whole budget converging the safe
		// checks silently skip the follow-up round entirely.
		function converge(budget: Int): Void {
			final limit: Int = passes + budget;
			while (active.length > 0) {
				if (passes >= limit) {
					hitCap = true;
					break;
				}
				passes++;
				final pass: LintPassResult = applyLintPass(
					active, files, cached, split.activeScope, split.fullScope, split.safe, resolveConfig, applyEnablement, optsByFile,
					passes, noted, notedRewrites, changedFiles, ledger, coupled
				);
				fixedCount += pass.fixedDelta;
				active = pass.nextActive;
			}
		}
		converge(maxPasses);

		// The safe pass is applied under a NET when an oracle is configured: typecheck the
		// tree BEFORE writing, write, then typecheck again. A green-then-red transition is
		// the safe fixes' own doing, and the whole pass is rolled back.
		//
		// Without this the run reported `risky-fix skipped (oracle baseline does not
		// typecheck)` — a message about the wrong thing entirely. `FixVerifier`'s baseline
		// is measured AFTER the safe writes, so it was reporting damage the safe pass had
		// just done as a pre-existing condition, and left the tree un-typecheckable with no
		// hint that `--fix` was the cause. The insurance was disabled at exactly the moment
		// it was needed.
		final safePass: SafePassOutcome = commitSafeWrites(files, changedFiles, originalOf, coupled, oracleHxml, oracleDir);
		if (safePass.reverted) {
			CliIo.stderr(safePass.notice);
			return EXIT_RUNTIME;
		}

		// The bytes the SAFE loop settled on, so the follow-up round below can name exactly the
		// files the two verified phases went on to rewrite. Their own applied/reverted lists do
		// not answer that: a file already in `changedFiles` is not pushed twice, and a reverted
		// candidate leaves the file byte-identical to this snapshot.
		final settledOf: Map<String, String> = sourceSnapshot(files);

		// RiskyFix checks: applied ONLY when a compiler oracle is configured — each
		// candidate is typechecked and reverted if it breaks the build (FixVerifier);
		// otherwise left report-only. With no risky check present this block is a
		// no-op, so a real run (no risky builtin) is byte-identical to before the key.
		final risky: RiskyFixOutcome = LintFixVerify.verifyRiskyFixes(
			files, split.risky, cached, oracleHxml, oracleDir, optsByFile, changedFiles, ledger
		);
		fixedCount += risky.appliedCount;
		final riskyTail: String = risky.tail;

		// OracleAssisted checks (explicit-local-type's inference tail, explicit-type's return
		// types): applied ONLY with a compilerOracle — each finding's type is asked of a warm
		// display server, the edited files are re-typechecked, and any that break the build are
		// reverted to report-only (verifyOracleBatch). No oracle / no such check → inert.
		final oracleAssisted: Array<Check> = [for (c in checks) if (c is OracleAssisted) c];
		final oa: { tail: String, appliedCount: Int } = LintFixVerify.applyOracleAssistedFixes(
			files, oracleAssisted, cached, oracleHxml, oracleDir, optsByFile, changedFiles, resolveConfig, risky.coverage
		);
		fixedCount += oa.appliedCount;
		final oracleTail: String = oa.tail;

		// The follow-up convergence round: `followUpRound` re-enters the loop over whatever the two
		// verified phases above rewrote, since both of them write AFTER it has already converged.
		final followUp: SafePassOutcome = followUpRound(files, settledOf, list -> {
			final before: Int = fixedCount;
			active = list;
			converge(maxPasses);
			return fixedCount - before;
		}, coupled, changedFiles, oracleHxml, oracleDir);
		if (followUp.reverted) {
			CliIo.stderr(followUp.notice);
			return EXIT_RUNTIME;
		}

		final baselineTail: String = safePass.tail;
		final skipTail: String = LintFixLedger.skippedTail(noted, changedFiles);
		// Names the per-ROUND budget, not the run total: `passes` spans both rounds now, so the old
		// wording produced `over 12 pass(es) (stopped at 10 passes …)` — a line that reads as a
		// contradiction rather than as the two budgets it actually reports.
		final capTail: String = hitCap ? ' (a round stopped at its $maxPasses-pass budget — re-run if more remain)' : '';
		CliIo.stderr(
			'${LintFixLedger.lintFixSummary(fixedCount, changedFiles.length, passes)}$skipTail$capTail$baselineTail$riskyTail$oracleTail'
			+ '${followUp.tail}\n'
		);
		// What the run did NOT fix, per rule. Its own block, not a tail on the line above, which is
		// what every gate and doc quotes and stays one sentence. It also prints on a PRODUCTIVE
		// run, which the tail it replaces did not — `fixed 0` was the only trigger, so this 668-fix
		// tree said nothing whatever about the 161 findings it declined, and a productive run is
		// exactly where the misreading lands.
		LintFixLedger.printUnfixedLedger(ledger, checks, split.risky, oracleAssisted, risky.ledgered);
		// The summary says HOW MANY reverted; these say WHICH, and by which rule. One line per
		// revert, nothing else: attributing three of them on an 809-file tree otherwise costs an
		// md5 snapshot before and after plus one run per candidate rule.
		for (r in risky.reverts)
			CliIo.stderr('apq lint --fix: risky-fix REVERTED ${r.file} (${r.rule}): ${LintFixVerify.revertCauseText(r.cause)}\n');
		// And WHICH code the oracle cannot speak for at all. The count alone would leave the
		// reader to guess which of hundreds of files this hxml never typechecks — the same search
		// the revert lines above exist to remove. Capped by `DECLINE_LINES_SHOWN`, unlike the
		// reverts above: a revert is rare by construction, a decline is not.
		for (i in 0...risky.declines.length) {
			final d: FixVerifyDecline = risky.declines[i];
			if (i >= DECLINE_LINES_SHOWN) {
				CliIo.stderr('apq lint --fix: … and ${risky.declines.length - DECLINE_LINES_SHOWN} more risky-fix decline(s) not listed\n');
				break;
			}
			CliIo.stderr('apq lint --fix: risky-fix DECLINED ${d.file} (${d.rule}): ${d.reason} — ${d.edits} edit(s) left report-only\n');
		}
		return EXIT_OK;
	}

	/**
	 * Run one --fix pass: rebuild the SymbolIndex over the current (mutated)
	 * sources, lint the active subset (active-scope checks) plus the full
	 * set (cross-file checks), then per active file collect + canonicalize
	 * its fixes. Returns the files changed this pass (eligible next pass)
	 * and the count of edits applied. Mutates `changedFiles`, `noted` (the
	 * SKIPPED-file set the run summary counts) and `notedRewrites` (the
	 * writer-rewrites note's own once-per-file set).
	 */
	public static function applyLintPass(
		active: Array<{ file: String, source: String }>, files: Array<{ file: String, source: String }>, cached: CachingGrammarPlugin,
		activeScopeChecks: Array<Check>, fullScopeChecks: Array<Check>, checks: Array<Check>, resolveConfig: (String) -> LintConfig,
		applyEnablement: Bool, optsByFile: Map<String, Null<String>>, passes: Int, noted: Array<String>, notedRewrites: Array<String>,
		changedFiles: Array<String>, ledger: Map<String, RuleFixOutcome>, coupled: Array<Array<String>>
	): LintPassResult {
		// The `index` PASSED to each check's `fix` is REPORT-scoped (the mutated report sources
		// only): a fix's report-scope gates — naming's confinement / reflection-string / rtti proofs,
		// prefer-final-field's confinement — reason about what a REPORT file can reach, and a
		// library file that skip-parses (openfl / lime carry a few) must not poison them. The
		// resolution-scoped index (report UNION library) rides the HOST instead, so a check's
		// resolution gate (naming's inherited-member proof) resolves a library supertype through
		// `SymbolIndexHost.resolutionIndex()`. Both rebuild per pass over this pass's sources.
		final index: SymbolIndex = SymbolIndex.build(files, cached);
		final resolutionFiles: Null<Array<{ file: String, source: String }>> = cached.resolutionFiles();
		if (resolutionFiles != null) cached.setResolutionIndex(SymbolIndex.build(resolutionFiles, cached));
		final violations: Array<Violation> = Linter.run(active, cached, activeScopeChecks, resolveConfig, applyEnablement);
		for (v in Linter.run(files, cached, fullScopeChecks, resolveConfig, applyEnablement)) violations.push(v);
		// The FIRST pass's report is the one a reader compares `fixed N` against: later passes see
		// only what an earlier edit exposed. Recorded here so the run can say WHICH rules reported
		// and — through the decline half of the same ledger, filled in below where each `fix` is
		// actually called — which of them answered with no edit.
		if (passes == 1) for (v in violations) ledgerFor(ledger, v.rule).reported++;
		final nextActive: Array<{ file: String, source: String }> = [];
		var fixedDelta: Int = 0;
		// Cross-file fixes (naming's non-confined private / public member rename) run FIRST, against this
		// pass's pristine sources so every slice matches the index. Renames that share a target file
		// are grouped into one component and committed together (all its files canonicalize or none)
		// — so a mega-class's many field renames all land in ONE pass instead of serialising across
		// passes. A committed file joins `touchedThisPass`, so the per-file loop skips it this pass.
		final touchedThisPass: Array<String> = [];
		final crossRenames: Array<Array<CrossFileEdits>> = [];
		for (check in checks) if (check is CrossFileFix) {
			final own: Array<Violation> = violations.filter(v -> v.rule == check.id());
			for (rename in (cast check: CrossFileFix).crossFileFix(files, own, cached, index)) {
				crossRenames.push(rename);
				// The ledger's "produced N edit(s) elsewhere" arm is a claim about the WHOLE rule, so it
				// has to see this path too. `naming` fixes a non-confined member ONLY here, and a ledger
				// blind to it would report the one rule that renames across files as having answered
				// nothing at all — the exact shape of claim this whole block exists to stop making.
				for (slice in rename) ledgerFor(ledger, check.id()).edits += slice.edits.length;
			}
		}
		fixedDelta += applyCrossFileRenames(crossRenames, files, optsByFile, cached, touchedThisPass, changedFiles, nextActive, coupled);
		for (entry in active) if (!touchedThisPass.contains(entry.file)) {
			final fileViolations: Array<Violation> = violations.filter(v -> v.file == entry.file);
			if (fileViolations.length == 0) continue;
			final groups: Array<RuleEdits> = collectFileLintEdits(entry.source, fileViolations, checks, cached, index);
			if (contributedEdits(groups).length == 0) {
				ledgerFileLintEdits(ledger, groups, passes == 1);
				continue;
			}
			var settled: Null<{ text: String, rewrites: Null<Int> }> = null;
			switch CanonicalEdit.canonicalize(entry.source, contributedEdits(groups), false, cached, optsByFile[entry.file]) {
				case Ok(text, rewrites):
					settled = { text: text, rewrites: rewrites };
				case Err(message):
					// PER-EDIT, not per-FILE. The gate round-trips the whole spliced file, so one
					// check's un-writable fix used to discard every other check's edits for this
					// file — on every pass, since each pass recomputes the same set and is refused
					// again. Measured over 8645 external files: 2 files where one refused edit set
					// (`modifier-order` reordering across a `/*inline*/`, `cond-region-merge`
					// emitting text that does not re-parse) cost 100+ landable edits from twenty-odd
					// other rules. The salvage runs ONLY here, so a file nothing refuses pays exactly
					// the one round trip it always did.
					final blamed: Array<String> = [];
					settled = salvageFileLintEdits(entry.source, groups, message, cached, optsByFile[entry.file], blamed);
					// EVERY pass, not just the first: `noted` already dedupes per file, so the
					// `passes == 1` this used to also carry bought nothing and cost the one place a
					// slot emptied BETWEEN two checks can land — a per-check look cannot see that
					// pair, so this backstop is its only report, and it was muted exactly where the
					// backstop is the whole point. It is also what the run summary counts as
					// `N file(s) skipped`, so a later-pass refusal used to leave the file unwritten
					// AND uncounted (`skippedTail` says `partly fixed first, then refused` when the
					// salvage did land the rest).
					if (!noted.contains(entry.file)) {
						CliIo.stderr('apq lint --fix: ${entry.file}: ${blamed.length == 0 ? message : blamed.join('; ')}\n');
						noted.push(entry.file);
					}
			}
			// AFTER the gate, never during collection: a check whose edits the writer refuses achieved
			// nothing, and counting them as `edits` there claimed the rule had fixed those findings.
			ledgerFileLintEdits(ledger, groups, passes == 1);
			if (settled != null) fixedDelta += commitLintPassFile(entry, groups, settled, notedRewrites, changedFiles, nextActive);
		}
		return { nextActive: nextActive, fixedDelta: fixedDelta };
	}

	/**
	 * Commit every cross-file `rename` this pass. Renames that share a target file are grouped into
	 * one component and committed together: the component's per-file edits are unioned (distinct
	 * fields → pairwise-disjoint spans) and each file canonicalized once — all files or none, so any
	 * one file's canonicalization failure reverts the whole component. Components touch disjoint
	 * files, so every commit-able one lands in this pass (no serialisation across passes). A
	 * committed file is written back into `files` and marked touched / changed / active. Returns the
	 * number of edits applied.
	 */
	private static function applyCrossFileRenames(
		renames: Array<Array<CrossFileEdits>>, files: Array<{ file: String, source: String }>, optsByFile: Map<String, Null<String>>,
		cached: GrammarPlugin, touchedThisPass: Array<String>, changedFiles: Array<String>,
		nextActive: Array<{ file: String, source: String }>, coupled: Array<Array<String>>
	): Int {
		var total: Int = 0;
		for (component in crossFileComponents(renames)) {
			final byFile: Map<String, Array<{ span: Span, text: String }>> = [];
			final slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }> = [];
			for (rename in component) for (slice in rename) {
				var edits: Null<Array<{ span: Span, text: String }>> = byFile[slice.file];
				if (edits == null) {
					edits = [];
					byFile[slice.file] = edits;
					slices.push({ file: slice.file, edits: edits });
				}
				for (e in slice.edits) edits.push(e);
			}
			final staged: Null<Array<{ file: String, source: String }>> = CanonicalEdit.stageCrossFileRename(
				slices, file -> fileSourceOf(files, file),
				(file, source, edits) -> CanonicalEdit.canonicalize(source, edits, false, cached, optsByFile[file])
			);
			if (staged == null) continue;
			for (s in staged) for (entry in files) if (entry.file == s.file) {
				entry.source = s.source;
				if (!touchedThisPass.contains(s.file)) touchedThisPass.push(s.file);
				if (!changedFiles.contains(s.file)) changedFiles.push(s.file);
				if (!containsFile(nextActive, s.file)) nextActive.push(entry);
				break;
			}
			// A component is committed whole, so the safe-pass revert must roll it back whole:
			// reverting half a rename leaves the tree worse off than reverting all of it.
			if (staged.length > 1) coupled.push([for (s in staged) s.file]);
			for (slice in slices) total += slice.edits.length;
		}
		return total;
	}

	/**
	 * Partition `renames` into connected components — two renames join when they share any target
	 * file — via union-find. Different components touch disjoint files, so each can be committed
	 * independently and atomically in the same pass. Preserves discovery order within and across
	 * components.
	 */
	private static function crossFileComponents(renames: Array<Array<CrossFileEdits>>): Array<Array<Array<CrossFileEdits>>> {
		final n: Int = renames.length;
		final parent: Array<Int> = [for (i in 0...n) i];
		function find(x: Int): Int {
			var r: Int = x;
			while (parent[r] != r) r = parent[r];
			while (parent[x] != r) {
				final next: Int = parent[x];
				parent[x] = r;
				x = next;
			}
			return r;
		}
		final fileOwner: Map<String, Int> = [];
		for (i in 0...n) for (slice in renames[i]) {
			final owner: Null<Int> = fileOwner[slice.file];
			if (owner == null)
				fileOwner[slice.file] = i;
			else {
				final ra: Int = find(i);
				final rb: Int = find(owner);
				if (ra != rb) parent[ra] = rb;
			}
		}
		final groups: Map<Int, Array<Array<CrossFileEdits>>> = [];
		final out: Array<Array<Array<CrossFileEdits>>> = [];
		for (i in 0...n) {
			final root: Int = find(i);
			var g: Null<Array<Array<CrossFileEdits>>> = groups[root];
			if (g == null) {
				g = [];
				groups[root] = g;
				out.push(g);
			}
			g.push(renames[i]);
		}
		return out;
	}

	/** The in-memory source of `name` in `files`, or null when absent. */
	private static function fileSourceOf(files: Array<{ file: String, source: String }>, name: String): Null<String> {
		for (entry in files) if (entry.file == name) return entry.source;
		return null;
	}

	/** Whether `list` already holds an entry for `name`. */
	private static function containsFile(list: Array<{ file: String, source: String }>, name: String): Bool {
		return list.exists(e -> e.file == name);
	}

	/**
	 * Ask every check for its fix edits over one file's violations, returning ONE GROUP PER CHECK —
	 * the edits, the findings they answer, whether an earlier check this pass already claimed an
	 * overlapping region, and the sentence of any gate that refused them.
	 *
	 * Grouped rather than flattened because the writer-emit gate's verdict is per FILE: without the
	 * attribution the driver could neither say which check's edits it would not write nor keep the
	 * others. `contributedEdits` flattens the survivors into the disjoint set the gate is handed.
	 */
	public static function collectFileLintEdits(
		source: String, fileViolations: Array<Violation>, checks: Array<Check>, cached: GrammarPlugin, index: SymbolIndex
	): Array<RuleEdits> {
		final groups: Array<RuleEdits> = [];
		final edits: Array<{ span: Span, text: String }> = [];
		for (check in checks) {
			final own: Array<Violation> = fileViolations.filter(v -> v.rule == check.id());
			if (own.length == 0) continue;
			final checkEdits: Array<{ span: Span, text: String }> = check.fix(source, own, cached, index);
			// The guard runs BEFORE the ledger, because the ledger's subject is what the check
			// ACHIEVED and a refused edit set achieves nothing. Counting it as `edits` claimed the rule
			// had fixed these findings, so the run reported no decline for them at all — and the one
			// sentence anyone had about why, the guard's own message, was computed right here and
			// thrown away against `null`. A refusal is now the row's verdict, in the guard's words.
			//
			// It also now runs for an edit set the overlap test below would have short-circuited past.
			// That is the point: an overlap is temporary and the deferred check fires cleanly next
			// pass, while a gate refusal is a standing fact about those edits, so recording the
			// refusal rather than "1 edit produced" is the truer of the two readings.
			final refused: Null<String> = checkEdits.length > 0
				? BodySlotGuard.emptiedSlot(source, checkEdits, cached) ?? DefiniteAssignmentGuard.unassignedRead(
					source, checkEdits, cached
				)
				: null;
			// Accept a check's edits only when none overlaps an edit already accepted from
			// an earlier check this pass — applying a subset would break an atomic fix
			// (e.g. unused-parameter's signature edit without its call-site arg edit, when
			// prefer-ternary-return rewrites the enclosing region). A deferred check fires
			// cleanly on the next fixed-point pass.
			// Drop a check's edits when they would empty a brace-less construct's body slot,
			// the same way an overlap does — per CHECK, so one `unused-local` inside an
			// `if (c) var y = 1;` costs its own fix and not the other rules' work on the file.
			// `canonicalize` refuses the same shape for the whole file; that stays the backstop
			// for a slot two checks empty between them, which no per-check look can see —
			// and `salvageFileLintEdits` now asks it per check when it fires.
			final overlapped: Bool = checkEdits.length > 0 && refused == null && CanonicalEdit.editsOverlapAny(checkEdits, edits);
			final group: RuleEdits = {
				rule: check.id(),
				findings: own,
				edits: checkEdits,
				overlapped: overlapped,
				refusal: refused
			};
			if (contributes(group)) for (e in checkEdits) edits.push(e);
			groups.push(group);
		}
		return groups;
	}

	/**
	 * Write one file's settled text back into the in-memory set and mark it for the next pass,
	 * answering how many edits that commits. Split out of `applyLintPass` to keep that function
	 * under the complexity budget.
	 */
	private static function commitLintPassFile(
		entry: { file: String, source: String }, groups: Array<RuleEdits>, settled: { text: String, rewrites: Null<Int> },
		notedRewrites: Array<String>, changedFiles: Array<String>, nextActive: Array<{ file: String, source: String }>
	): Int {
		// `notedRewrites`, NOT `noted`: --fix runs several passes and a writer that needs two rewrites
		// on a file needs them on every pass that touches it, so the note needs a dedupe set — but
		// `noted` is the SKIPPED-file set the run summary counts, and a file that merely tripped this
		// note was fixed.
		if (FormatFixedPoint.rewritesNote(settled.rewrites) != null && !notedRewrites.contains(entry.file)) {
			CliEdit.warnRewrites('lint --fix', entry.file, settled.rewrites);
			notedRewrites.push(entry.file);
		}
		if (settled.text == entry.source) return 0;
		entry.source = settled.text;
		if (!changedFiles.contains(entry.file)) changedFiles.push(entry.file);
		nextActive.push(entry);
		return contributedEdits(groups).length;
	}

	/** Whether `group`'s edits reach the file's edit set: the check answered, no gate refused it, no earlier check overlapped it. */
	private static inline function contributes(group: RuleEdits): Bool {
		return group.edits.length > 0 && group.refusal == null && !group.overlapped;
	}

	/** The disjoint edit set `groups` currently contribute, in check order — recomputed, so a refusal recorded later shrinks it. */
	public static function contributedEdits(groups: Array<RuleEdits>): Array<{ span: Span, text: String }> {
		return CanonicalEdit.dropContainedEdits([for (group in groups) if (contributes(group)) for (e in group.edits) e]);
	}

	/**
	 * Re-ask the writer-emit gate one CHECK at a time after it refused the file's whole edit set:
	 * returns the canonicalized text of the largest subset that survives (null when none does), and
	 * names each refused rule in `blamed`.
	 *
	 * `RefactorSupport.canonicalize` round-trips the whole spliced file, so its verdict is per FILE
	 * and one check's un-writable fix cost every other check's work on that file, every pass.
	 *
	 * A source the writer cannot round-trip AT ALL is told apart FIRST, by asking the gate with an
	 * EMPTY edit set: no subset of edits changes that answer, so there is nothing to bisect and every
	 * contributing group takes the file-level sentence. That case is the bulk of it — 50 of the 54
	 * refusals measured over 8645 external files, the same files `apq fmt --write` refuses — which is
	 * why "the rule proposed what the writer refuses" explains almost none of this defect.
	 *
	 * The granularity is the CHECK, not the edit, because that is where a fix is atomic: splitting one
	 * check's set would apply a signature edit without its call-site edits. Greedy in check order, so
	 * the surviving set is MAXIMAL rather than maximum (checks whose pairs A+B and A+C are refused
	 * while B+C is fine keep A and blame both others), and a refusal caused by the COMBINATION of two
	 * checks is charged to the later one — the same first-come rule the overlap test applies.
	 */
	public static function salvageFileLintEdits(
		source: String, groups: Array<RuleEdits>, message: String, cached: GrammarPlugin, optsJson: Null<String>, blamed: Array<String>
	): Null<{ text: String, rewrites: Null<Int> }> {
		switch CanonicalEdit.canonicalize(source, [], false, cached, optsJson) {
			case Ok(_, _):
			case Err(_):
				// The loop's OWN predicate, never `contributes` — that one excludes an OVERLAPPED
				// group, and on this arm nothing is ever written, so such a group's edits did not land
				// either. Read through `contributes` it got no refusal row and the ledger then credited
				// it with edits on a run that wrote nothing. This arm is 50 of the 54 refusals measured
				// over 8645 files, so it is the common path, not the corner.
				for (group in groups) if (group.edits.length > 0 && group.refusal == null) group.refusal = message;
				return null;
		}
		// Overlap is RE-DERIVED on the bisect arm against the SURVIVING set, never read off the collection pass. A
		// group deferred because it overlapped one the gate then REFUSES would otherwise never be
		// offered at all — and every pass recomputes the same state, so its edits would be lost for
		// ever: the very defect this salvage exists to close, one level down. Measured before the
		// re-derivation: a `redundant-parens` edit inside the region a refused
		// `prefer-if-expression-assignment` fix covered stayed unwritten across every pass, and the run
		// blamed only the rule that was actually refused.
		final kept: Array<RuleEdits> = [];
		final keptEdits: Array<{ span: Span, text: String }> = [];
		var settled: Null<{ text: String, rewrites: Null<Int> }> = null;
		for (group in groups) if (group.edits.length > 0 && group.refusal == null) {
			if (CanonicalEdit.editsOverlapAny(group.edits, keptEdits)) {
				group.overlapped = true;
				continue;
			}
			group.overlapped = false;
			kept.push(group);
			switch CanonicalEdit.canonicalize(source, contributedEdits(kept), false, cached, optsJson) {
				case Ok(text, rewrites):
					settled = { text: text, rewrites: rewrites };
					for (e in group.edits) keptEdits.push(e);
				case Err(why):
					kept.pop();
					group.refusal = why;
					blamed.push('${group.rule}: $why');
			}
		}
		return settled;
	}

	/**
	 * Fold one file's per-check outcomes into the run's fix ledger, AFTER the writer-emit gate has
	 * answered.
	 *
	 * The ONE place in the tool that knows what a check answered for a given set of its own findings,
	 * and now also whether the driver could write it: "no edit came back" and "the edits were refused"
	 * are both facts only this path holds, and every reading of them downstream was a guess. An
	 * OVERLAPPED group still counts its edits, deliberately: on the paths where the file IS written an
	 * overlap is temporary — the salvage re-derives it against the survivors, so a check deferred
	 * behind a refused one is offered in the same pass and one deferred behind a WRITTEN one fires on
	 * the next. Where nothing is written at all (a source the writer cannot round-trip) the salvage
	 * gives every group that produced edits the file-level refusal instead, so none of them reaches
	 * this row claiming an edit.
	 */
	public static function ledgerFileLintEdits(ledger: Map<String, RuleFixOutcome>, groups: Array<RuleEdits>, countDeclines: Bool): Void {
		for (group in groups)
			noteFixOutcome(
				ledger, group.rule, group.findings, group.refusal == null ? group.edits.length : 0, countDeclines, group.refusal
			);
	}

	/**
	 * `rule`'s ledger row, created empty on first sight. Every writer goes through here so a
	 * rule that reports before it is ever asked for a fix (and one asked before it reports,
	 * on a later pass) share one row instead of racing to create two.
	 */
	public static function ledgerFor(ledger: Map<String, RuleFixOutcome>, rule: String): RuleFixOutcome {
		final found: Null<RuleFixOutcome> = ledger[rule];
		if (found != null) return found;
		final created: RuleFixOutcome = {
			reported: 0,
			declined: 0,
			edits: 0,
			reasons: [],
			refusals: []
		};
		ledger[rule] = created;
		return created;
	}

	/**
	 * Record what `rule`'s `Check.fix` answered for `own` — `editCount` edits for those findings.
	 *
	 * `edits` accumulates on EVERY pass: one edit anywhere is proof the rule HAS an autofix, and
	 * that single bit is what two slices got wrong by reading `fixed 0 issue(s)`. `declined` is
	 * counted only when `countDeclines` (the first pass), so it stays comparable with `reported`
	 * — a later pass re-reports whatever an earlier edit exposed, and summing those would count
	 * one finding several times.
	 *
	 * The REASON is never invented here, but it has two sources. Normally it is whatever the check
	 * itself wrote on its own findings (`Violation.declineReason`); when the writer-emit gate REFUSED
	 * the check's edits, `refusal` carries the gate's own sentence and stands for all of them — the
	 * check answered, the driver threw the answer away, and the driver is the only one that can say
	 * so. A rule that says nothing either way leaves it null and the ledger reports only what it
	 * observed.
	 */
	private static function noteFixOutcome(
		ledger: Map<String, RuleFixOutcome>, rule: String, own: Array<Violation>, editCount: Int, countDeclines: Bool, ?refusal: String
	): Void {
		final entry: RuleFixOutcome = ledgerFor(ledger, rule);
		entry.edits += editCount;
		if (editCount != 0) {
			notePartialDeclines(entry, own, countDeclines);
			return;
		}
		// EVERY pass, and counted in EDIT SETS rather than findings — the whole point of it having a
		// list of its own. A gate refusal is not a re-report of what an earlier edit exposed, it is a
		// standing fact about these edits and the only sentence anyone gets about why the fix
		// vanished; `declined` cannot carry it, because `declined` has to stay a FIRST-pass count to
		// stay comparable with `reported`, and the same findings come back refused every later pass.
		// A refusal first landing on pass 2 used to reach no report at all.
		if (refusal != null) bumpReason(entry.refusals, refusal, 1);
		if (!countDeclines) return;
		entry.declined += own.length;
		// Counted over exactly the findings `declined` counts, so the two numbers are comparable:
		// a reason total BELOW `declined` says the check spoke for some of them and not the rest,
		// which is a fact about the check, not an artefact of where the counting happened.
		for (v in own) {
			final reason: Null<String> = refusal ?? v.declineReason;
			if (reason != null) bumpReason(entry.reasons, reason, 1);
		}
	}

	/**
	 * Count the findings a check declined in a call that DID return edits — the ones it fixed some
	 * of and refused the rest of.
	 *
	 * The ledger read a non-empty edit list as "this rule answered", and every finding in the same
	 * call that it had refused went unmentioned: no `declined` count, no reason, no row. Measured on
	 * this project's own tree, `member-order` declined 13 of its 26 findings and the run named 11 —
	 * the two missing ones were containers whose reorder was refused while their BLANK-LINE fix
	 * landed, so the rule's edit count for that file was non-zero and the refusal disappeared.
	 *
	 * Only a finding the check itself SPOKE for is counted here. A silent one cannot be: the call
	 * returned edits, so "no edit for this finding" is not derivable from the edit list — a check is
	 * free to fix three findings with one span. `Violation.declineReason` is the only evidence that
	 * a specific finding was refused, which is exactly what makes writing it the check's job.
	 */
	private static function notePartialDeclines(entry: RuleFixOutcome, own: Array<Violation>, countDeclines: Bool): Void {
		if (!countDeclines) return;
		for (v in own) {
			final reason: Null<String> = v.declineReason;
			if (reason == null) continue;
			entry.declined++;
			bumpReason(entry.reasons, reason, 1);
		}
	}

	/**
	 * Add `count` to `list`'s row for `text`, creating it on first sight.
	 *
	 * The shape BOTH sentence lists share (`reasons`, `refusals`): one row per distinct sentence with
	 * the number of things that carried it, never one sentence per rule. What that number counts is the
	 * caller's to say — findings for `reasons`, refused edit sets for `refusals`.
	 */
	public static function bumpReason(list: Array<{ text: String, count: Int }>, text: String, count: Int): Void {
		final seen: Null<{ text: String, count: Int }> = list.find(r -> r.text == text);
		if (seen == null)
			list.push({ text: text, count: count })
		else
			seen.count += count;
	}

	/**
	 * Reconcile the safe pass against the compiler, given the verdict taken BEFORE its
	 * writes landed. `LintFixSafePass` owns every judgement; this seat owns the IO — the
	 * file sink that restores a file from `originalOf` (on disk and in `files`) and the
	 * oracle spawns the narrowing drives.
	 *
	 * A failing pass no longer costs the whole wave: `LintFixSafePass.narrow` reverts the
	 * files the compiler blames and keeps the rest, falling back to the whole-wave
	 * rollback only when nothing the run wrote can be implicated. Either way the caller
	 * aborts, with a notice that NAMES what went back.
	 *
	 * Split out of `applyLintFixes` to keep that function under the complexity budget.
	 */
	private static function reconcileSafePass(
		files: Array<{ file: String, source: String }>, changedFiles: Array<String>, originalOf: Map<String, String>,
		coupled: Array<Array<String>>, pre: Null<OracleOutcome>, oracleHxml: Null<String>, oracleDir: Null<String>
	): SafePassOutcome {
		if (pre == null || oracleHxml == null) return { reverted: false, tail: '', notice: '' };
		final resolved: OracleOutcome = pre;
		// Both re-bound as non-null locals: a PARAMETER's narrowing does not survive into the
		// closures below, and both are read from inside one.
		final hxml: String = oracleHxml;
		final decision: SafePassDecision = LintFixSafePass.classify(
			resolved, LintFixSafePass.isConfirmed(resolved) ? CompilerOracle.typecheck(hxml, oracleDir) : null
		);
		final errors: String = switch decision {
			case Proceed: return { reverted: false, tail: '', notice: '' };
			case NoNet(tail): return { reverted: false, tail: tail, notice: '' };
			case Revert(text): text;
		};
		// ONE `writeFiles`, not a write per file. This is the ROLLBACK path, reached because the
		// tree already fails to typecheck, and a rollback that stops half way leaves precisely the
		// mixed state `writeFiles` exists to prevent — with no second chance, since the wave it was
		// undoing is what made the tree red.
		function restore(list: Array<String>): Void {
			final undo: Array<{ path: String, content: String }> = [];
			for (entry in files) if (list.contains(entry.file)) {
				final original: String = originalOf[entry.file] ?? entry.source;
				entry.source = original;
				undo.push({
					path: entry.file,
					content: original
				});
			}
			CliIo.writeFiles(undo);
		}
		final narrowing: SafePassNarrowing = LintFixSafePass.narrow(
			errors, changedFiles, coupled, restore, CompilerOracle.typecheck.bind(hxml, oracleDir), LintFixSafePass.NARROW_ROUNDS
		);
		// `narrow` reverted whatever it could attribute; an un-narrowable wave still owes the
		// caller's own whole-wave rollback, which is the behaviour this net had before.
		switch narrowing {
			case Narrowed(_, _):
			case WholeWave(_):
				restore(changedFiles);
		}
		return { reverted: true, tail: '', notice: LintFixSafePass.revertNotice(narrowing, changedFiles.length, errors) };
	}

	/** Every file's current bytes, keyed by path - the baseline a later round measures its own writes against. */
	private static function sourceSnapshot(files: Array<{ file: String, source: String }>): Map<String, String> {
		final snapshot: Map<String, String> = [];
		for (entry in files) snapshot[entry.file] = entry.source;
		return snapshot;
	}

	/** The entries whose in-memory source has moved since `snapshot` was taken. */
	private static function changedSince(
		files: Array<{ file: String, source: String }>, snapshot: Map<String, String>
	): Array<{ file: String, source: String }> {
		return [for (entry in files) if (entry.source != snapshot[entry.file]) entry];
	}

	/**
	 * Write `changed` to disk under the green-then-red net: typecheck BEFORE writing, write, typecheck
	 * again, and roll the wave back when a tree that was green turned red. Shared by the first safe
	 * round and by the follow-up round after the verified phases - both commit UNVERIFIED fixes over a
	 * tree the previous phase left green, so both owe the same insurance, and a second hand-written
	 * copy of this dance is exactly how one of them would come to lack it.
	 */
	private static function commitSafeWrites(
		files: Array<{ file: String, source: String }>, changed: Array<String>, originalOf: Map<String, String>,
		coupled: Array<Array<String>>, oracleHxml: Null<String>, oracleDir: Null<String>
	): SafePassOutcome {
		final baseline: Null<OracleOutcome> = oracleHxml != null && changed.length > 0
			? CompilerOracle.typecheck(oracleHxml, oracleDir)
			: null;
		CliIo.writeFiles([
			for (entry in files) if (changed.contains(entry.file)) { path: entry.file, content: entry.source }
		]);
		return reconcileSafePass(files, changed, originalOf, coupled, baseline, oracleHxml, oracleDir);
	}

	/**
	 * Re-enter the safe fixed-point loop over the files the VERIFIED phases rewrote.
	 *
	 * `verifyRiskyFixes` and `applyOracleAssistedFixes` both write after the safe loop has converged,
	 * so until this round existed every finding their edits EXPOSED was left in the tree by the run
	 * that created it: `--fix` printed a success line, and a byte-identical second invocation of the
	 * same command fixed more. The motivating pair is `prefer-inline` and `member-order` - marking a
	 * method `inline` moves it under the within-rank sub-order, and the loop that would have re-sorted
	 * it had already finished. Measured on Pony (867 files, oracle configured): 5 fixes in 3 files.
	 *
	 * `converge` is the caller's own loop, passed as a closure because it owns the run-wide counters;
	 * it takes the active set and answers how many fixes the round made. The net restores the bytes
	 * the VERIFIED phases left, never the ones the safe loop settled on - rolling back to the latter
	 * would undo an oracle-CONFIRMED risky fix as collateral for a follow-up edit that broke the
	 * build. A run with no oracle reaches here with nothing changed and returns at the first line.
	 */
	private static function followUpRound(
		files: Array<{ file: String, source: String }>, settledOf: Map<String, String>,
		converge: (Array<{ file: String, source: String }>) -> Int, coupled: Array<Array<String>>, changedFiles: Array<String>,
		oracleHxml: Null<String>, oracleDir: Null<String>
	): SafePassOutcome {
		final quiet: SafePassOutcome = { reverted: false, tail: '', notice: '' };
		final verifiedChanged: Array<{ file: String, source: String }> = changedSince(files, settledOf);
		if (verifiedChanged.length == 0) return quiet;
		final verifiedOf: Map<String, String> = sourceSnapshot(files);
		final fixed: Int = converge(verifiedChanged);
		// Over ALL files, not just `verifiedChanged`: a cross-file rename in this round commits slices
		// into files the verified phases never touched.
		final rewritten: Array<String> = [for (entry in changedSince(files, verifiedOf)) entry.file];
		if (rewritten.length == 0) return quiet;
		for (f in rewritten) if (!changedFiles.contains(f)) changedFiles.push(f);
		final pass: SafePassOutcome = commitSafeWrites(files, rewritten, verifiedOf, coupled, oracleHxml, oracleDir);
		return {
			reverted: pass.reverted,
			tail: '${pass.tail}, follow-up: $fixed edit(s) in ${rewritten.length} file(s) exposed by the verified phases',
			notice: pass.notice
		};
	}

	/**
	 * The `--fix` half of `runLint`, split out so the fix path's own `--no-oracle` branch does not
	 * cost `runLint` complexity budget it has none of.
	 *
	 * `--no-oracle` means the compiler is not asked ANYTHING this run, in fix mode as much as in
	 * report mode. The flag used to be read only by the report path, so `--fix --no-oracle` still
	 * spawned the project-wide typecheck AND still silently reverted whole waves — an iteration
	 * loop could not see its own fixer's raw output, and the flag's own stderr note (report mode
	 * only) never appeared to contradict it. Handing `applyLintFixes` a null hxml is exactly
	 * "behave as if the project configured no compilerOracle": no safe-pass revert net, risky
	 * fixes stay report-only, oracle-assisted checks stay inert. That makes the flag more dangerous in fix
	 * mode than in report mode, which is what the usage text now says.
	 *
	 * The same netless state is reached WITHOUT the flag, by a project that configured no
	 * `compilerOracle` at all — the state every foreign project starts in — and that arm used
	 * to print nothing. Both now go through `LintFixSafePass.netNotice`, which says the net is
	 * off and names the remedy for whichever arm it is.
	 */
	public static function runLintFix(
		files: Array<{ file: String, source: String }>, checks: Array<Check>, plugin: GrammarPlugin, resolveConfig: (String) -> LintConfig,
		applyEnablement: Bool, resolution: Null<ResolutionScope>, oracleHxml: Null<String>, oracleDir: Null<String>, noOracle: Bool
	): Int {
		FmtCommand.warnCommentGuardDeclined();
		// Said BEFORE the first write, and said in both netless arms — the flag the user passed
		// and the config key they never added. `LintFixSafePass.netNotice` owns which.
		final notice: Null<String> = LintFixSafePass.netNotice(oracleHxml, noOracle);
		if (notice != null) CliIo.stderr(notice);
		return !noOracle
			? applyLintFixes(files, checks, plugin, resolveConfig, applyEnablement, resolution, oracleHxml, oracleDir)
			: applyLintFixes(files, checks, plugin, resolveConfig, applyEnablement, resolution);
	}

}
