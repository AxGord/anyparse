package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.query.Cli.RuleFixOutcome;

using StringTools;
using Lambda;

/**
 * What `apq lint --fix` could NOT fix, rendered.
 *
 * A fixer that declines is the interesting half of a fix run, and the reasons
 * come from three places (a check with no `fix()`, a gate refusal, an oracle
 * revert). The ledger is what makes them one report.
 */
@:nullSafety(Strict)
final class LintFixLedger {

	#if (sys || nodejs)
	/**
	 * The head of the `lint --fix` run summary, and it reports EDIT SPANS.
	 *
	 * A check answers with one span per site it rewrites, so ONE `naming` finding on a local read
	 * three times is four spans; a fix whose result exposes a further finding adds that pass's
	 * spans on top of them. Printed as `fixed N issue(s)` it read as a finding count and disagreed
	 * with the number the reader had just counted in the plain `lint` report — measured at 4 for 3
	 * findings on a cascading fold, and at 4 for exactly ONE finding with no cascade anywhere in
	 * the run.
	 *
	 * The finding total is still not here beside it, and the reason it was given is now half fixed
	 * rather than true. `edits` sums the safe loop AND the risky and oracle-assisted phases, while
	 * the `ledger` was filled by the safe loop alone, so the two were measured over two different
	 * RULE SETS; `FixVerifier` carries per-rule tallies now and `ledgerRiskyTallies` folds them in,
	 * which closes that half on the one path where the risky phase actually ran.
	 *
	 * Two differences remain and neither is a rule set. The first is the MOMENT: `reported` is a
	 * FIRST-pass count for the safe rules and a single-run count for the risky ones, and an
	 * `OracleAssisted` rule's second pass adds edits under a row whose findings were counted before
	 * it ran. The second is the GATES: `FixVerifier` collects through `Linter.collect`, which
	 * applies the reification and inline-suppression gates and nothing else — no `resolveConfig`,
	 * no enablement inversion, no version gate, no per-file severity — and `applyLintFixes` relaxes
	 * the `OracleRelaxable` risky checks before it, so a risky rule's row here can count findings a
	 * plain `lint` would not report. The finding total belongs to that plain `lint`, which runs
	 * every rule once under its own config; what each rule DECLINED is `unfixedFixLedger`'s block
	 * below.
	 */
	public static function lintFixSummary(edits: Int, files: Int, passes: Int): String {
		return 'apq lint --fix: $edits edit(s) in $files file(s) over $passes pass(es)';
	}

	/**
	 * The summary line's `N file(s) skipped` tail — and the one thing it could not say before.
	 *
	 * `noted` and `changedFiles` OVERLAP now. The `canonicalize` backstop reports on EVERY pass, which
	 * is what makes it the only report a slot two checks empty BETWEEN them can ever get; so a file
	 * fixed on pass 1 and refused on pass 2 lands in both sets, and `skipped` on its own read as
	 * "nothing was written here" for a file the run had already rewritten. The parenthetical is the
	 * whole difference between "never fixed" and "partly fixed, then refused", and it is absent when
	 * the count is zero — a run whose two sets are disjoint prints the bytes it always printed.
	 */
	public static function skippedTail(noted: Array<String>, changedFiles: Array<String>): String {
		if (noted.length == 0) return '';
		var partly: Int = 0;
		for (file in noted) if (changedFiles.contains(file)) partly++;
		return partly == 0
			? ', ${noted.length} file(s) skipped'
			: ', ${noted.length} file(s) skipped ($partly partly fixed first, then refused)';
	}

	/**
	 * The `lint --fix` block naming, per rule, the findings that got NO edit from their own check —
	 * and which of the things that can mean happened to each.
	 *
	 * The summary line answered none of that. Its ambiguous companion tail printed ONLY when the run
	 * changed nothing, so a 668-fix tree said not one word about the 161 findings it declined; and the
	 * tail itself spelled the ambiguity out rather than resolving it ("the check has no autofix, or when
	 * its fix declined here"), which three readers resolved the wrong way and two of them filed work on.
	 *
	 * A row counts the DECLINED findings, not the reported ones — a finding whose check answered
	 * with an edit is not news — so a run that fixed everything it reported, and a clean run, both
	 * print nothing. `riskyIds` are the rules this run never asked at all; they are named once at
	 * the end rather than shown as silent zeroes, and a run whose risky phase DID ask them passes
	 * an empty list because `ledgerRiskyTallies` has given each of them a row of its own.
	 */
	public static function unfixedFixLedger(
		ledger: Map<String, RuleFixOutcome>, noAutofixReasons: Map<String, String>, oracleAssistedIds: Array<String>,
		riskyIds: Array<String>
	): Array<String> {
		final rows: Array<{
			rule: String,
			count: Int,
			reported: Int,
			verdict: String,
			detail: Array<String>,
			declared: Bool
		}> = [];
		for (rule => entry in ledger) if (entry.declined != 0) {
			final declared: Null<String> = noAutofixReasons[rule];
			rows.push({
				rule: rule,
				count: entry.declined,
				reported: entry.reported,
				verdict: unfixedVerdict(entry, declared, oracleAssistedIds.contains(rule)),
				detail: declared != null ? [] : reasonLines(entry.reasons, entry.declined),
				declared: declared != null || entry.reasons.length > 0
			});
		}
		// Its own block, NOT rows here: these counts are edit SETS refused over every pass, and the
		// rows above count first-pass FINDINGS. Summing the two into one header would state a number
		// that means neither.
		final refused: Array<String> = gateRefusalLines(ledger);
		if (rows.length == 0) return refused;
		rows.sort((a, b) -> a.count != b.count ? b.count - a.count : Reflect.compare(a.rule, b.rule));
		var total: Int = 0;
		for (row in rows) total += row.count;
		final lines: Array<String> = [
			'apq lint --fix: $total reported finding(s) in ${rows.length} rule(s) got NO edit from their own check:\n'
		];
		// `<n> of <reported>` only when `reported` is the LARGER of the two — that gap IS the
		// "fixed some, declined the rest" case, and a reader who cannot see it reads a partial
		// decline as a total one. The other direction is not that case at all: `reported` is a
		// PASS-1 count the driver fills in `applyLintPass`, so a caller that drives
		// `computeFileLintEdits` on its own (every test here, and any future embedder) leaves it at
		// zero while `declined` counts real findings — and the label then read `unused-local 2 of 0`,
		// a ratio out of a total that is smaller than its own part.
		for (row in rows.slice(0, LintFixDriver.DECLINED_RULES_SHOWN)) {
			final label: String = row.count >= row.reported ? '${row.rule} ${row.count}' : '${row.rule} ${row.count} of ${row.reported}';
			lines.push('  $label: ${row.verdict}\n');
			for (line in row.detail) lines.push(line);
		}
		if (rows.length > LintFixDriver.DECLINED_RULES_SHOWN) {
			var rest: Int = 0;
			for (row in rows.slice(LintFixDriver.DECLINED_RULES_SHOWN)) rest += row.count;
			lines.push('  ... +${rows.length - LintFixDriver.DECLINED_RULES_SHOWN} more rule(s), $rest finding(s)\n');
		}
		// `riskyIds` arrives EMPTY from a run whose risky phase ran, because `FixVerifier` now
		// carries per-(rule, file) tallies and `ledgerRiskyTallies` folds them into rows here. What
		// is left is the run that never asked those rules at all — no oracle, an oracle that would
		// not start, a tree that does not typecheck — and for that the disclaimer is the answer.
		// An `OracleAssisted` rule that is not also risky DOES run in the safe loop, so it has a row
		// either way; listing it as absent was the first version of this line and it contradicted
		// the row three lines above it.
		if (riskyIds.length > 0)
			lines.push(
				'apq lint --fix: ${riskyIds.length} rule(s) are absent from this ledger — the risky-fix path never ran them this '
				+ 'run (${riskyIds.join(', ')}); the summary line above says why, and is their whole verdict.\n'
			);
		if (rows.exists(row -> !row.declared))
			lines.push(
				'apq lint --fix: a rule above that declared NOTHING is not thereby a rule that CANNOT fix — a decline most often needs a '
				+ 'WIDER scope than this run (a member rename must see every file that could collide). Re-run over the project root, and '
				+ 'see `Check.NoAutofix` / `Violation.declineReason` for what a rule owes its reader here.\n'
			);
		for (line in refused) lines.push(line);
		return lines;
	}

	/**
	 * The block naming every rule whose edits the writer-emit gate REFUSED and the ledger above does
	 * not account for — a refusal that first landed after pass 1, or one whose sentence the
	 * first-pass reasons never carried.
	 *
	 * Its own block, and its counts are edit SETS rather than findings, because `declined` has to stay
	 * a FIRST-pass measurement to be comparable with `reported`: a later pass re-reports whatever an
	 * earlier edit exposed, so folding those findings in would count one of them once per pass. A
	 * refusal is no re-report though — it is a standing fact about an edit set, and the gate's
	 * sentence is the only word a run has about why that fix vanished. Uncapped, because the row
	 * count is bounded by the rule registry rather than by the tree.
	 */
	private static function gateRefusalLines(ledger: Map<String, RuleFixOutcome>): Array<String> {
		final rows: Array<{ rule: String, count: Int, texts: Array<String> }> = [];
		for (rule => entry in ledger) {
			final unseen: Array<{ text: String, count: Int }> = entry.refusals.filter(r -> !entry.reasons.exists(x -> x.text == r.text));
			if (unseen.length == 0) continue;
			var count: Int = 0;
			for (r in unseen) count += r.count;
			rows.push({ rule: rule, count: count, texts: [for (r in unseen) r.text] });
		}
		if (rows.length == 0) return [];
		rows.sort((a, b) -> a.count != b.count ? b.count - a.count : Reflect.compare(a.rule, b.rule));
		final lines: Array<String> = [
			'apq lint --fix: the writer-emit gate REFUSED ${rows.length} rule(s) the block above does not account for — their'
				+ ' edits were computed and thrown away, and this is the only word the run has on why:\n'
		];
		for (row in rows) {
			final distinct: Int = row.texts.length;
			lines.push(
				distinct == 1
					? '  ${row.rule}: ${row.count} edit set(s) refused — ${row.texts[0]}\n'
					: '  ${row.rule}: ${row.count} edit set(s) refused, $distinct distinct reason(s)\n'
			);
			if (distinct > 1) for (text in row.texts) lines.push('      $text\n');
		}
		return lines;
	}

	/**
	 * Which of the things an unfixed finding can MEAN happened to `entry`'s.
	 *
	 * The order is by strength of evidence, and the last arm is the honest default: a check that
	 * declared nothing gets only the observation (its fix was called and answered no edit), never
	 * the claim that it HAS no fix. The `edits > 0` arm is the one no declaration is needed for —
	 * a rule that produced an edit somewhere this run has PROVED it can fix, so its silence here
	 * is a decline whatever it says.
	 */
	private static function unfixedVerdict(entry: RuleFixOutcome, noAutofixReason: Null<String>, oracleAssisted: Bool): String {
		final verdict: String = plainUnfixedVerdict(entry, noAutofixReason);
		// An OracleAssisted rule has a SECOND fix path this ledger never sees (it runs once, after
		// the loop, against a warm display server). Saying only what the safe loop observed would
		// under-report a rule whose oracle pass did land edits.
		return oracleAssisted ? '$verdict — and this rule has an oracle-assisted pass besides, counted on the summary line above' : verdict;
	}

	/**
	 * The verdict from what the SAFE loop observed, before the oracle-assisted note is added.
	 *
	 * The arms are in order of how strong the evidence is, and the last one is the honest default:
	 * a check that declared nothing gets the observation (its fix was called, no edit came back),
	 * never the claim that it HAS no fix — that claim, made by a reader rather than by the tool, is
	 * what this whole block exists to stop. The `edits > 0` arm needs no declaration at all: a rule
	 * that produced an edit somewhere this run has PROVED it can fix.
	 */
	private static function plainUnfixedVerdict(entry: RuleFixOutcome, noAutofixReason: Null<String>): String {
		if (noAutofixReason != null) return 'no autofix by design — $noAutofixReason';
		final reasons: Array<{ text: String, count: Int }> = entry.reasons;
		return if (reasons.length == 1 && reasons[0].count == entry.declined)
			'fix DECLINED — ${reasons[0].text}'
		else if (reasons.length > 0)
			// The head only; `declineReasonLines` spells the reasons out one per line under it. A
			// rule that declines for several DIFFERENT reasons cannot be answered on one line, and
			// picking one of them is how a quarter of an answer acquires the confidence of a whole.
			'fix DECLINED, ${reasons.length} distinct reason(s) over ${entry.declined} finding(s)'
		else if (entry.edits > 0)
			'fix declined here, yet the rule produced ${entry.edits} edit(s) elsewhere in this run — so it HAS'
				+ ' an autofix and withheld it, without saying why'
		else
			'its fix was called for these findings and returned no edit; the check declares neither NoAutofix nor a decline reason,'
				+ ' so the run will not say which it is';
	}

	/**
	 * The `<count>× <reason>` sub-lines under a rule's row, strongest first, against the `total`
	 * findings that row counts.
	 *
	 * Empty for the two cases the row itself already answers in full: no reason at all (the row carries
	 * the measured default), and one reason covering every finding (the row carries it inline, in the
	 * exact bytes the single-reason form has always printed).
	 *
	 * The trailing `declared no reason for these` count is the honest remainder — a check that declines
	 * at several sites and writes the reason at only some of them is a real state, and rounding the
	 * remainder into the reasons that WERE given would restate the defect this block exists to end. A
	 * writer-emit gate refusal the first-pass reasons never carried is not here at all: it counts edit
	 * sets rather than findings, so `gateRefusalLines` reports it under its own header.
	 */
	private static function reasonLines(reasons: Array<{ text: String, count: Int }>, total: Int): Array<String> {
		if (reasons.length == 0 || (reasons.length == 1 && reasons[0].count == total)) return [];
		final sorted: Array<{ text: String, count: Int }> = reasons.copy();
		sorted.sort((a, b) -> a.count != b.count ? b.count - a.count : Reflect.compare(a.text, b.text));
		final out: Array<String> = [];
		var explained: Int = 0;
		for (reason in sorted.slice(0, LintFixDriver.DECLINED_REASONS_SHOWN)) {
			out.push('      ${reason.count}× ${reason.text}\n');
			explained += reason.count;
		}
		if (sorted.length > LintFixDriver.DECLINED_REASONS_SHOWN) {
			var rest: Int = 0;
			for (reason in sorted.slice(LintFixDriver.DECLINED_REASONS_SHOWN)) rest += reason.count;
			out.push('      ... +${sorted.length - LintFixDriver.DECLINED_REASONS_SHOWN} more reason(s), $rest finding(s)\n');
			explained += rest;
		}
		final silent: Int = total - explained;
		if (silent > 0) out.push('      $silent× — the check declared no reason for these\n');
		return out;
	}

	/**
	 * Which rules this run actually EXERCISED, and — the whole point — which it did not.
	 *
	 * The proof every slice of this campaign closes on is `lint --all --fix` over a real tree run
	 * by two engines, the outputs byte-compared. That is a strong statement about a rule whose fix
	 * produced an edit and NO statement whatever about one the tree never triggered, and until now
	 * a run said nothing that told the two apart. It is not a hypothetical gap: `trivial-getter`
	 * has zero occurrences in every corpus this project owns — anyparse `src test`, the Pony fork
	 * working tree and its `git HEAD`, the haxe-formatter fork — so a slice touching it could quote
	 * "the trees are byte-identical" and have proved nothing at all.
	 *
	 * Four buckets, all of them read off numbers the ledger already carried: an edit landed, a
	 * finding came back with no edit, the run never asked the rule at all (`notAsked` — the
	 * risky-fix set a netless run leaves report-only), nothing was reported. They partition the
	 * rule set by construction, so the four counts sum to `ruleIds.length` and a reader can check
	 * the arithmetic on the line itself.
	 *
	 * The NAMES printed are the exercised ones rather than the silent ones. That is the SHORT list
	 * on a real tree (48 of 175 on Pony) and the only short answer there is on a one-file run,
	 * where the silent list would be 170-odd ids of pure noise; and it is the positive form of the
	 * claim, so a reader looking for their own rule gets an answer instead of an absence to
	 * interpret.
	 */
	public static function exerciseCensus(
		ledger: Map<String, RuleFixOutcome>, ruleIds: Array<String>, notAsked: Array<String>
	): Array<String> {
		// Partitioned by construction rather than by four counters over one loop: `never` is then a
		// SUBTRACTION and the four buckets cannot fail to sum to the rule set, which is the one
		// property the printed line asks its reader to check. It also counts a `notAsked` id that is
		// not in `ruleIds` at all as neither — `notAsked.length` would have counted it.
		final asked: Array<String> = [for (id in ruleIds) if (!notAsked.contains(id)) id];
		final never: Int = ruleIds.length - asked.length;
		final exercised: Array<String> = [];
		var reportedOnly: Int = 0;
		var silent: Int = 0;
		for (id in asked) {
			final entry: Null<RuleFixOutcome> = ledger[id];
			if (entry == null)
				silent++;
			else if (entry.edits > 0)
				exercised.push(id);
			else
				reportedOnly++;
		}
		exercised.sort((a, b) -> Reflect.compare(a, b));
		return [
			'apq lint --fix: rule census — of the ${ruleIds.length} rule(s) this run was given, ${exercised.length} produced an edit, '
				+ '$reportedOnly reported and got none, $never were never asked, $silent reported nothing at all. Comparing what this run '
				+ 'wrote against another engine is evidence about the first group and about none of the other three.\n',
			exercised.length == 0
				? '  exercised: none — this run rewrote nothing, so it stands as evidence about no rule at all\n'
				: '  exercised: ${exercised.join(', ')}\n'
		];
	}

	/**
	 * Every line the `--fix` run owes its reader about the rules: what got no edit, then what the
	 * run exercised at all.
	 *
	 * `risky` is passed so a run that could NOT verify its risky rules can name them: a `RiskyFix`
	 * check is excluded from the safe loop, so on such a run no `Check.fix` of its own is ever
	 * called and its row would be a silent zero. Naming them is what keeps the block from reading
	 * as though it LOST the largest rule on the tree — on Pony `avoid-dynamic` alone reports 470 —
	 * and the summary line above already carries why the phase did not run.
	 *
	 * `riskyLedgered` says the opposite happened: the phase ran, `FixVerifier` tallied it, and
	 * `ledgerRiskyTallies` folded those tallies into rows here. Then the list must be empty, or the
	 * footer would disclaim a rule whose own row sits three lines above it.
	 *
	 * `oracleAssisted` is a third case and was got wrong first time round: such a rule DOES run in
	 * the safe loop (unless it is risky too), so it has a row here — its extra oracle pass is noted
	 * ON that row rather than by claiming the rule is absent.
	 *
	 * It returns the lines instead of writing them because `CliIo.stderr` is a process write with
	 * no seam a test can read, and the census is exactly the kind of block a later edit drops
	 * silently — the composition is the only part of it a pin can hold.
	 */
	public static function ledgerLines(
		ledger: Map<String, RuleFixOutcome>, checks: Array<Check>, risky: Array<Check>, oracleAssisted: Array<Check>, riskyLedgered: Bool
	): Array<String> {
		// Empty when the risky phase RAN: its rules then have rows of their own here, and the
		// footer that names them as absent would contradict the row three lines above it.
		final riskyIds: Array<String> = riskyLedgered ? [] : [for (c in risky) c.id()];
		riskyIds.sort((a, b) -> Reflect.compare(a, b));
		final oracleIds: Array<String> = [for (c in oracleAssisted) c.id()];
		final reasons: Map<String, String> = [
			for (c in checks) if (c is NoAutofix) c.id() => (cast c: NoAutofix).noAutofixReason()
		];
		final lines: Array<String> = unfixedFixLedger(ledger, reasons, oracleIds, riskyIds);
		for (line in exerciseCensus(ledger, [for (c in checks) c.id()], riskyIds)) lines.push(line);
		return lines;
	}

	/** Write `ledgerLines` to stderr — the one call that turns the run's rule accounting into output. */
	public static function printUnfixedLedger(
		ledger: Map<String, RuleFixOutcome>, checks: Array<Check>, risky: Array<Check>, oracleAssisted: Array<Check>, riskyLedgered: Bool
	): Void {
		for (line in ledgerLines(ledger, checks, risky, oracleAssisted, riskyLedgered)) CliIo.stderr(line);
	}
	#end

}
