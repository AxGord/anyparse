package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.FragmentedDocComment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

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
		return new FragmentedDocComment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: FragmentedDocComment = new FragmentedDocComment();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
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
