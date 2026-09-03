package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.CondRegionMerge;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import utest.Assert;
import utest.Test;

/**
 * The `cond-region-merge` check: two adjacent conditional-compilation regions saying the same thing
 * are one region spelled twice, and the boundary between them — an `#end` immediately followed by an
 * `#if` — is deleted, or replaced by `#else` when the conditions are complementary.
 *
 * The fixtures below pin BOTH halves of the rule: the four combinations of branch shape and
 * condition relation that splice soundly, and the ones that do not — a shape whose merge would need
 * code to MOVE, and the adjacency gates (code in the gap, an `#elseif`, an unbalanced scan). The
 * check is a pure source scan, so the positions exercised include a class body, a statement list and
 * a file the grammar cannot parse.
 */
class CondRegionMergeCheckTest extends Test {

	public function testSameConditionRegionsFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\t#if mobile\n\t\ta();\n\t\t#end\n\n\t\t#if mobile\n\t\tb();\n\t\t#end\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('cond-region-merge', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('mobile') >= 0);
	}

	public function testSameConditionRegionsMerged(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\t#if mobile\n\t\ta();\n\t\t#end\n\n\t\t#if mobile\n\t\tb();\n\t\t#end\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if mobile\n\t\ta();\n\n\t\tb();\n\t\t#end\n\t}\n}', applyFix(src));
	}

	/** The second region's `#else` becomes the merged region's, meaning the negation of the same condition. */
	public function testSecondRegionElseKept(): Void {
		final src: String = '#if mobile\na();\n#end\n\n#if mobile\nb();\n#else\nc();\n#end\n';
		Assert.equals(1, violations(src).length);
		Assert.equals('#if mobile\na();\n\nb();\n#else\nc();\n#end\n', applyFix(src));
	}

	/** The motivating shape: an `#else` branch IS `!cond`, so the region guarded by `!cond` below it merges into it. */
	public function testNegatedRegionAbsorbedIntoElseBranch(): Void {
		final src: String = 'class C {\n\t#if flag\n\tfunction a():Void {}\n\t#else\n\tfunction b():Void {}\n\t#end\n\n\t#if !flag\n'
			+ '\tfunction c():Void {}\n\t#end\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('#else') >= 0);
		Assert.equals(
			'class C {\n\t#if flag\n\tfunction a():Void {}\n\t#else\n\tfunction b():Void {}\n\n\tfunction c():Void {}\n\t#end\n}',
			applyFix(src)
		);
	}

	public function testComplementaryRegionsBecomeElse(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\t#if mobile\n\t\ta();\n\t\t#end\n\n\t\t#if !mobile\n\t\tb();\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if mobile\n\t\ta();\n\t\t#else\n\t\tb();\n\t\t#end\n\t}\n}', applyFix(src));
	}

	/** A parenthesised negation is the same condition negated - `!(mobile)` against `mobile`. */
	public function testParenthesisedNegationRecognised(): Void {
		Assert.equals(1, violations('#if mobile\na();\n#end\n\n#if !(mobile)\nb();\n#end\n').length);
	}

	/**
	 * The load-bearing gate: a statement between the two regions makes them a false pair — merging
	 * would move that statement out from between them.
	 */
	public function testCodeBetweenRegionsRefused(): Void {
		Assert.equals(0, violations('#if verbose\nlog();\n#end\nlock();\n#if verbose\nlog();\n#end\n').length);
	}

	/** An `#elseif` chain's `#else` would change meaning in the merged chain, so the region refuses. */
	public function testElseIfRefused(): Void {
		Assert.equals(0, violations('#if a\nx();\n#elseif b\ny();\n#end\n\n#if a\nz();\n#end\n').length);
	}

	/** The second region's `#else` body belongs to the FIRST condition, so it would have to jump ahead of its own body. */
	public function testNegatedSecondRegionWithElseRefused(): Void {
		Assert.equals(0, violations('#if a\nx();\n#end\n\n#if !a\ny();\n#else\nz();\n#end\n').length);
	}

	/** With the same condition, the second region's body would land in the first's `#else` — under the negation. */
	public function testSameConditionAfterElseRefused(): Void {
		Assert.equals(0, violations('#if a\nx();\n#else\ny();\n#end\n\n#if a\nz();\n#end\n').length);
	}

	public function testUnrelatedConditionsRefused(): Void {
		Assert.equals(0, violations('#if a\nx();\n#end\n\n#if b\ny();\n#end\n').length);
	}

	/** A region model that did not close cannot say which branch a body is in, so an unbalanced scan refuses the file. */
	public function testUnbalancedScanRefusesFile(): Void {
		Assert.equals(0, violations('#if a\nx();\n#end\n#end\n\n#if a\ny();\n#end\n').length);
	}

	/** Deleting the `#end` line would delete the note written on it, so the finding stays report-only. */
	public function testTrailingCommentLeavesReportOnly(): Void {
		final src: String = '#if mobile\na();\n#end // keep\n#if mobile\nb();\n#end\n';
		assertReportOnly(src);
	}

	/**
	 * A comment BETWEEN the two regions would end up INSIDE the merged one — and a doc comment
	 * written there belongs to whatever follows the second `#end`, whose documentation would become
	 * conditional — so the finding is reported and left unfixed.
	 */
	public function testCommentBetweenRegionsLeavesReportOnly(): Void {
		final src: String = '#if mobile\na();\n#end\n// note\n#if mobile\nb();\n#end\n';
		assertReportOnly(src);
	}

	/** Three regions in a row are one merge per pass: the middle one is already paired when its own pair is considered. */
	public function testChainMergesOnePairPerPass(): Void {
		final src: String = '#if a\nx();\n#end\n\n#if a\ny();\n#end\n\n#if a\nz();\n#end\n';
		Assert.equals(1, violations(src).length);
		Assert.equals('#if a\nx();\n\ny();\n#end\n\n#if a\nz();\n#end\n', applyFix(src));
	}

	public function testCrlfLineEndings(): Void {
		Assert.equals(
			'#if mobile\r\na();\r\n#else\r\nb();\r\n#end\r\n',
			applyFix('#if mobile\r\na();\r\n#end\r\n\r\n#if !mobile\r\nb();\r\n#end\r\n')
		);
	}

	/**
	 * `fix` is handed a SUBSET of what `run` reported whenever a finding was suppressed or another
	 * rule's edits won an overlap, so it must edit exactly the sites it was given.
	 */
	public function testFixEditsOnlyTheGivenSubset(): Void {
		final src: String = '#if a\nx();\n#end\n\n#if a\ny();\n#end\n\nfoo();\n\n#if b\np();\n#end\n\n#if b\nq();\n#end\n';
		final check: CondRegionMerge = new CondRegionMerge();
		final all: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(2, all.length);
		final edited: String = RefactorSupport.applyEdits(src, check.fix(src, [all[1]], new HaxeQueryPlugin()));
		Assert.equals('#if a\nx();\n#end\n\n#if a\ny();\n#end\n\nfoo();\n\n#if b\np();\n\nq();\n#end\n', edited);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('cond-region-merge'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('cond-region-merge'));
	}

	/** The check never parses, so a file the grammar chokes on is scanned like any other. */
	public function testUnparseableSourceStillScanned(): Void {
		Assert.equals(1, violations('class Bad {\n\t#if a\n\tfunction f() { \n\t#end\n\n\t#if a\n\tfunction g() { \n\t#end\n').length);
	}

	/** Assert `src` produces exactly one finding, noted as report-only, and that the fix leaves the source untouched. */
	private function assertReportOnly(src: String): Void {
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('merge by hand') >= 0);
		Assert.equals(src, applyFix(src));
	}

	private function violations(src: String): Array<Violation> {
		return new CondRegionMerge().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: CondRegionMerge = new CondRegionMerge();
		return RefactorSupport.applyEdits(
			src, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin())
		);
	}

}
