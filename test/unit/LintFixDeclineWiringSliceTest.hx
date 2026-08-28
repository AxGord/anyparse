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
 * Both pins go through the private statics the driver is made of (`@:access`), because the
 * output itself is a `Sys.stderr` write with no seam a test can read.
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
		final ledger: Map<String, {
			reported: Int,
			declined: Int,
			edits: Int,
			reasons: Array<{ text: String, count: Int }>
		}> = [];
		final edits: Array<{ span: Span, text: String }> = Cli.computeFileLintEdits(
			REFUSED, own, [check], plugin, SymbolIndex.build(files, plugin), ledger, true
		);
		Assert.equals(0, edits.length, 'the guard drops the check edits');
		final row: Null<{
			reported: Int,
			declined: Int,
			edits: Int,
			reasons: Array<{ text: String, count: Int }>
		}> = ledger['unused-local'];
		if (row == null) {
			Assert.fail('the refused rule has no ledger row');
			return;
		}
		Assert.equals(0, row.edits, 'an edit the gate refused is not an edit the rule produced');
		Assert.equals(own.length, row.declined, 'the findings it could not fix are counted as declined');
		Assert.equals(1, row.reasons.length, 'one reason, the guard\'s: ${row.reasons}');
		if (row.reasons.length == 0) return;
		Assert.isTrue(row.reasons[0].text.indexOf('IfStmt') != -1, 'the reason names the construct: ${row.reasons[0].text}');
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

}
