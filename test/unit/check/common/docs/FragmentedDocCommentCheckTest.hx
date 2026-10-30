package unit.check.common.docs;

import anyparse.check.Severity;
import anyparse.check.common.docs.FragmentedDocComment;

/**
 * The `fragmented-doc-comment` check: a declaration documented by several adjacent
 * block comments (each opened and closed separately) is flagged `Info` and `--fix`
 * merges them into one. A blank line between blocks, a line comment, or a single
 * block are left alone.
 */
class FragmentedDocCommentCheckTest extends Test {

	public function testTwoAdjacentBlocksFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t/** one. */\n\t/** two. */\n\tpublic var x:Int = 0;\n}');
		Assert.equals(1, vs.length);
		Assert.equals('fragmented-doc-comment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testBlankLineBetweenNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t/** one. */\n\n\t/** two. */\n\tpublic var x:Int = 0;\n}').length);
	}

	public function testLineCommentNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t/** one. */\n\t// two\n\tpublic var x:Int = 0;\n}').length);
	}

	public function testSingleBlockNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t/** one. */\n\tpublic var x:Int = 0;\n}').length);
	}

	public function testFixMergesBodies(): Void {
		final fixed: String = fixedSource('class C {\n\t/** one. */\n\t/**\n\t * two.\n\t */\n\tpublic var x:Int = 0;\n}');
		Assert.isTrue(fixed.indexOf('one.') >= 0 && fixed.indexOf('two.') >= 0, 'both bodies kept: $fixed');
		Assert.equals(1, countOccurrences(fixed, '/**'), 'exactly one doc block now: $fixed');
	}

	/**
	 * Two blocks that each open a doc — an orphan of a moved helper above the next member's own doc — stay as written,
	 * and the finding says why; a later block continuing the earlier one's text is still merged.
	 */
	@:pin('control')
	@:killer('M-FRAGMENTED-DOC-MERGES-ORPHAN')
	public function testTwoWholeDocsAreNotMerged(): Void {
		final src: String = 'class C {\n\t/** Run the check over `src`. */\n\t/**\n\t * Tabs are kept.\n\t */\n\tpublic var x:Int = 0;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(src, fixedSource(src));
		final check: FragmentedDocComment = new FragmentedDocComment();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, found, new HaxeQueryPlugin()).length);
		Assert.notNull(found[0].declineReason);
		final codeSpans: String = 'class C {\n\t/** `helper` reads the cache. */\n\t/** `x` is the width. */\n\tpublic var x:Int = 0;\n}';
		Assert.equals(codeSpans, fixedSource(codeSpans), 'a doc opening with a code span is a doc of its own');
		Assert.equals(
			1, countOccurrences(fixedSource('class C {\n\t/** Run the check */\n\t/** over `src`. */\n\tpublic var x:Int = 0;\n}'), '/**')
		);
	}

	public function testThreeBlocksMergedToOne(): Void {
		final src: String = 'class C {\n\t/** a */\n\t/** b */\n\t/** c */\n\tpublic var x:Int = 0;\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, countOccurrences(fixedSource(src), '/**'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('fragmented-doc-comment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('fragmented-doc-comment'));
	}

	public function testNoCrashOnEmpty(): Void {
		Assert.equals(0, violations('class C {}').length);
	}

	/** Plain (non-doc) block comments — a license header above a doc, or two notes — are NOT a fragmented doc. */
	public function testPlainBlocksNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t/* license */\n\t/** real doc. */\n\tpublic var x:Int = 0;\n}').length);
		Assert.equals(0, violations('class C {\n\t/* note a */\n\t/* note b */\n\tpublic var x:Int = 0;\n}').length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new FragmentedDocComment(), src);
	}

	private function fixedSource(src: String): String {
		return CheckFixture.fixedSource(new FragmentedDocComment(), src);
	}

	private function countOccurrences(s: String, sub: String): Int {
		var n: Int = 0;
		var i: Int = s.indexOf(sub);
		while (i >= 0) {
			n++;
			i = s.indexOf(sub, i + sub.length);
		}
		return n;
	}

}
