package unit;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * What `lint --fix` SAYS about an edit set the writer-emit gate refused, and about a refusal
 * that lands on a later pass.
 *
 * Two silences, both of them shaped so that nothing in a run's output contradicts them.
 *
 * `noteFixOutcome` used to run BEFORE the `BodySlotGuard` filter, so a check whose edits the
 * guard threw away was recorded as having produced them: `edits` went up, `declined` stayed at
 * zero, and the per-rule "reported but got no edit" block therefore had no row for the rule at
 * all. The guard had ALREADY computed the human-readable reason at that call site — it is the
 * value the filter compares to `null` — and the run discarded it.
 *
 * The `canonicalize` backstop under it was muted after pass 1 (`if (passes == 1 && …)`), which
 * is precisely where a slot emptied BETWEEN two checks lands: the per-check filter cannot see
 * a pair, so this is that pair's only report, and it also feeds the summary's
 * `N file(s) skipped`. A later-pass refusal left the file unwritten AND uncounted.
 *
 * The pins go through the private statics the driver is made of (`@:access`), because the output
 * itself is a `Sys.stderr` write with no seam a test can read.
 *
 * S34 added the other half of the same silence, and one wording. A refusal that first lands on a
 * LATER pass is not a re-report, so it cannot go into `declined` (a first-pass count, kept
 * comparable with `reported`) — it went nowhere at all, and `gateRefusalLines` is the block it
 * reaches now. And a file can be in BOTH `changedFiles` and `noted` since the backstop started
 * reporting every pass, so `N file(s) skipped` had stopped telling "never fixed" from "partly
 * fixed, then refused".
 */
@:access(anyparse.query.Cli)
class LintFixDeclineWiringSliceTest extends Test {

	/** `unused-local` on a declaration that IS a brace-less `if` body — the shape the guard refuses. */
	private static final REFUSED: String =
		'package p;\n\nclass C {\n\tpublic function f(c: Bool): Void {\n\t\tif (c) var y: Int = 1;\n\t}\n\n}\n';

	/** A fixable finding in a file the writer would reformat — `canonicalize` refuses it with `reformat` false. */
	private static final NOT_CANONICAL: String =
		'package p;\n\nclass C {\n    public function f(): Void {\n        var y: Int = 1;\n    }\n}\n';

	/**
	 * The guard's refusal is the rule's ledger row, and it carries the guard's own sentence.
	 *
	 * RED at base on all four assertions but the first: the edits were dropped either way, while
	 * the rule was credited with 1 edit, counted 0 declines and offered no reason.
	 */
	public function testGuardRefusalBecomesTheRulesDeclineRow(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: REFUSED }];
		final own: Array<Violation> = check.run(files, plugin);
		Assert.isTrue(own.length > 0, 'the fixture reports at least one unused-local finding');
		final ledger: Map<String, RuleFixOutcome> = [];
		final edits: Array<{ span: Span, text: String }> = Cli.computeFileLintEdits(
			REFUSED, own, [check], plugin, SymbolIndex.build(files, plugin), ledger, true
		);
		Assert.equals(0, edits.length, 'the guard drops the check edits');
		final row: Null<RuleFixOutcome> = ledger['unused-local'];
		if (row == null) {
			Assert.fail('the refused rule has no ledger row');
			return;
		}
		Assert.equals(0, row.edits, 'an edit the gate refused is not an edit the rule produced');
		Assert.equals(own.length, row.declined, 'the findings it could not fix are counted as declined');
		Assert.equals(1, row.reasons.length, 'one reason, the guard\'s: ${row.reasons}');
		if (row.reasons.length == 0) return;
		Assert.isTrue(row.reasons[0].text.indexOf('IfStmt') != -1, 'the reason names the construct: ${row.reasons[0].text}');
		// CONTROL for the `unseen` filter in `gateRefusalLines`: a refusal the DECLINE row already
		// carries must not be repeated as an unaccounted-for one. Drop that filter and this goes red
		// while the later-pass pin below stays green.
		final declared: Map<String, String> = [];
		final lines: String = Cli.unfixedFixLedger(ledger, declared, [], []).join('');
		Assert.isTrue(lines.indexOf('fix DECLINED — ') != -1, 'a pass-1 refusal IS the rule\'s decline row: $lines');
		Assert.isTrue(lines.indexOf('edit set(s) refused') == -1, 'and it is not repeated in the gate-refusal block: $lines');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `canonicalize` refusal on pass 2 is reported and counted, not dropped.
	 *
	 * `noted` IS the observable: the driver pushes the file there beside the stderr line, and the
	 * summary reads its length as `N file(s) skipped`. RED at base, where the whole arm sat behind
	 * `passes == 1`.
	 */
	public function testLaterPassRefusalIsStillReported(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: NOT_CANONICAL }];
		final noted: Array<String> = [];
		Cli.applyLintPass(
			files, files, plugin, [check], [], [check], _ -> LintConfig.parse('{}'), false, ['C.hx' => null], 2, noted, [], [], [], []
		);
		Assert.isTrue(noted.contains('C.hx'), 'the pass-2 refusal is reported and counted as a skipped file');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A gate refusal that first lands on a LATER pass still reaches the report, in the gate's own
	 * words.
	 *
	 * `declined` is a FIRST-pass count on purpose — a later pass re-reports whatever an earlier edit
	 * exposed, and summing those would count one finding several times — so a refusal, which is a
	 * standing fact about an edit set rather than a re-report, gets a list of its own and a block of
	 * its own. Without them `unfixedFixLedger` said nothing whatever about the rule, and that sentence
	 * is the ONLY thing telling a user why their fix vanished.
	 *
	 * RED at base: with `countDeclines` false the whole recording arm returned early, so the ledger
	 * produced no line naming the rule. The base-adapted copy spells the four-field anonymous shape
	 * inline, `RuleFixOutcome` having been private there.
	 */
	public function testLaterPassGateRefusalStillReachesTheReport(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: REFUSED }];
		final own: Array<Violation> = check.run(files, plugin);
		final ledger: Map<String, RuleFixOutcome> = [];
		// `countDeclines` false IS "this is not pass 1" — the driver passes `passes == 1`.
		final edits: Array<{ span: Span, text: String }> = Cli.computeFileLintEdits(
			REFUSED, own, [check], plugin, SymbolIndex.build(files, plugin), ledger, false
		);
		Assert.equals(0, edits.length, 'the guard drops the check edits on this pass too');
		final row: Null<RuleFixOutcome> = ledger['unused-local'];
		if (row == null) {
			Assert.fail('the refused rule has no ledger entry');
			return;
		}
		Assert.equals(0, row.declined, 'a later pass adds nothing to the first-pass decline count');
		Assert.equals(1, row.refusals.length, 'the gate refusal is recorded: ${row.refusals}');
		final declared: Map<String, String> = [];
		final lines: String = Cli.unfixedFixLedger(ledger, declared, [], []).join('');
		Assert.isTrue(lines.indexOf('unused-local') != -1, 'the rule reaches the report: $lines');
		Assert.isTrue(lines.indexOf('IfStmt') != -1, 'and the block carries the guard\'s own sentence: $lines');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The summary's skip tail tells "never fixed" from "partly fixed, then refused".
	 *
	 * `noted` and `changedFiles` can hold the SAME file since the `canonicalize` backstop started
	 * reporting on every pass: an edit landed on pass 1 and a later pass was refused. `N file(s)
	 * skipped` on its own then read as "nothing was written here" about a file the run had already
	 * rewritten.
	 *
	 * RED at base, where the tail was `noted.length > 0 ? ', N file(s) skipped' : ''` — an expression
	 * that cannot produce the parenthetical for any input.
	 */
	public function testSkipTailNamesThePartlyFixedFiles(): Void {
		#if (sys || nodejs)
		Assert.equals(', 2 file(s) skipped (1 partly fixed first, then refused)', Cli.skippedTail(['a.hx', 'b.hx'], ['a.hx']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * CONTROL: a run whose two sets are DISJOINT prints the bytes it always printed, and an empty
	 * `noted` prints nothing at all.
	 *
	 * Green by construction — the base tail expression yields exactly these two strings for these two
	 * inputs, so the change adds a case rather than moving one. Proved by MUTATION instead: make the
	 * parenthetical unconditional and this flips while the pin above stays green.
	 */
	public function testSkipTailIsUnchangedWhenNothingWasPartlyFixed(): Void {
		#if (sys || nodejs)
		Assert.equals(', 1 file(s) skipped', Cli.skippedTail(['a.hx'], ['b.hx']));
		Assert.equals('', Cli.skippedTail([], ['b.hx']));
		#else
		Assert.pass('non-sys target');
		#end
	}


	/**
	 * The decline row's `<n> of <reported>` label never states a part larger than its whole.
	 *
	 * `reported` is filled ONLY by the driver's pass-1 report loop in `applyLintPass`, so a caller
	 * that drives `computeFileLintEdits` itself — the pins above, and any embedder — leaves it at
	 * zero while `declined` counts real findings. The label's only test was `count == reported`, so
	 * the else arm fired and the run printed `unused-local 2 of 0`: a ratio out of a total smaller
	 * than its own part, in the one block that exists to explain why a fix vanished.
	 *
	 * RED at base, where the same ledger renders ` of 0`.
	 */
	public function testTheDeclineLabelNeverReadsOutOfZero(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('unused-local');
		if (check == null) {
			Assert.fail('unused-local is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: REFUSED }];
		final own: Array<Violation> = check.run(files, plugin);
		final ledger: Map<String, RuleFixOutcome> = [];
		Cli.computeFileLintEdits(REFUSED, own, [check], plugin, SymbolIndex.build(files, plugin), ledger, true);
		final row: Null<RuleFixOutcome> = ledger['unused-local'];
		if (row == null) {
			Assert.fail('the refused rule has no ledger row');
			return;
		}
		Assert.equals(0, row.reported, 'nothing on this path fills the pass-1 report count');
		Assert.isTrue(row.declined > 0, 'while the declines are real findings');
		final declared: Map<String, String> = [];
		final lines: String = Cli.unfixedFixLedger(ledger, declared, [], []).join('');
		Assert.isTrue(lines.indexOf(' of 0') == -1, 'the label states no ratio out of nothing: $lines');
		Assert.isTrue(lines.indexOf('unused-local ${row.declined}:') != -1, 'it states the plain count instead: $lines');
		#else
		Assert.pass('non-sys target');
		#end
	}

}
