package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.EmptyComment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `empty-comment` check: a content-free comment (a line comment with only
 * whitespace after the slashes, an empty block comment, or an empty doc comment
 * including multi-line ones whose interior is only stars and whitespace) is
 * flagged `Warning`. `fix` removes it — the whole physical line(s) when the
 * comment is alone on them, otherwise it strips the comment and rtrims the code
 * line. Deliberate dividers, directives, and any printable content are kept.
 */
class EmptyCommentCheckTest extends Test {

	public function testStandaloneLineCommentFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\t//\n\t\tg();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('empty-comment', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('empty comment', vs[0].message);
	}

	public function testTrailingLineCommentFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tg(); //\n\t}\n}').length);
	}

	public function testWhitespaceOnlyLineCommentFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t//   \t\n}').length);
	}

	public function testSeparatorLineKept(): Void {
		Assert.equals(0, violations('class C {\n\t//--------\n}').length);
	}

	/**
	 * A bare `//` between two comment-only lines is the blank line of a prose block, so it
	 * is kept and its `fix` is a no-op — deleting it would merge two paragraphs.
	 */
	public function testParagraphSeparatorKept(): Void {
		final src: String = 'class C {\n\t// first paragraph\n\t//\n\t// second paragraph\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * The gate's four boundaries, each still FLAGGED — every clause of
	 * `isParagraphSeparator` is a positive requirement, so exactly one broken clause per
	 * case discriminates:
	 *  - head of a run (nothing above to separate from);
	 *  - tail of a run (nothing below);
	 *  - a neighbour sharing its line with code (not a prose block);
	 *  - a neighbour a blank line away (the blank already separates).
	 */
	public function testParagraphSeparatorBoundariesStillFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t//\n\t// below only\n}').length);
		Assert.equals(1, violations('class C {\n\t// above only\n\t//\n}').length);
		Assert.equals(1, violations('class C {\n\tvar x:Int = 0; // above\n\t//\n\t// below\n}').length);
		Assert.equals(1, violations('class C {\n\t// above\n\n\t//\n\t// below\n}').length);
	}

	/**
	 * A block comment is not a `//` prose block: it carries its own paragraph breaks, so a
	 * bare `//` beside one is still noise. Each assertion isolates one side, and the third
	 * discriminates the gate's `tok.isLine` clause — an empty BLOCK comment between two
	 * prose lines passes every other clause and would be kept without it.
	 */
	public function testSeparatorBesideBlockCommentsFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/* above */\n\t//\n\t// below\n}').length);
		Assert.equals(1, violations('class C {\n\t// above\n\t//\n\t/* below */\n}').length);
		Assert.equals(1, violations('class C {\n\t// above\n\t/* */\n\t// below\n}').length);
	}

	/**
	 * A RUN of blank `//` lines inside a prose block keeps exactly ONE separator and reports
	 * the rest. That is what the "content above" clause buys: without it every blank of the
	 * run saw another blank beside it, all were kept, and the padding was unreducible;
	 * requiring content on BOTH sides would instead flag every blank and let the fix merge
	 * the two paragraphs. The fix output pins which one survives — the first.
	 */
	public function testBlankRunKeepsOneSeparator(): Void {
		final src: String = 'class C {\n\t// first\n\t//\n\t//\n\t//\n\t// second\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals('class C {\n\t// first\n\t//\n\t// second\n}', applyFix(src));
	}

	public function testNoqaDirectiveKept(): Void {
		Assert.equals(0, violations('class C {\n\tvar x:Int = 0; // noqa\n}').length);
	}

	public function testNonEmptyLineCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\t// a real comment\n}').length);
	}

	public function testEmptyBlockCommentFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/**/\n}').length);
	}

	public function testWhitespaceBlockCommentFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/*   */\n}').length);
	}

	public function testEmptyDocCommentFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/** */\n}').length);
	}

	public function testMultilineEmptyDocCommentFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/**\n\t *\n\t */\n}').length);
	}

	public function testNonEmptyBlockCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\t/* e */\n}').length);
	}

	public function testNonEmptyDocCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\t/** Returns x. */\n}').length);
	}

	public function testCommentInStringLiteralKept(): Void {
		Assert.equals(0, violations('class C {\n\tvar s:String = "//";\n}').length);
	}

	public function testFixRemovesStandaloneLine(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar day:Int = 0;\n\t\t//\n\t\tg(day);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tvar day:Int = 0;\n\t\tg(day);\n\t}\n}', applyFix(src));
	}

	public function testFixStripsTrailingComment(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(); //\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testFixRemovesEmptyBlockLine(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t/**/\n\t\tg();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testFixRemovesMultilineDoc(): Void {
		final src: String = 'class C {\n\t/**\n\t *\n\t */\n\tfunction f():Void {}\n}';
		Assert.equals('class C {\n\tfunction f():Void {}\n}', applyFix(src));
	}

	public function testSeparatorNotFixed(): Void {
		final src: String = 'class C {\n\t//--------\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('empty-comment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('empty-comment'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { /* ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new EmptyComment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new EmptyComment(), src);
	}

}
