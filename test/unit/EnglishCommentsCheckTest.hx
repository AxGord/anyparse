package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.EnglishComments;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `english-comments` check: a comment (line, block, or doc) containing a
 * non-Latin letter (Cyrillic, CJK, Arabic, ...) is flagged `Info` — comments must
 * be English only. Non-Latin content inside a STRING literal, Latin-extended
 * accents, emoji, arrows, and box-drawing are all left alone. Report-only — `fix`
 * yields no edits. Fixture sources keep their non-Latin text in double-quoted
 * strings, so this test file itself stays English-only under the check.
 */
class EnglishCommentsCheckTest extends Test {

	public function testCyrillicLineCommentFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// This is a russian word: привет\n}');
		Assert.equals(1, vs.length);
		Assert.equals('english-comments', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testCyrillicBlockAndDocFlagged(): Void {
		final vs: Array<Violation> = violations('/* блок */\n/** док */\nclass C {}');
		Assert.equals(2, vs.length);
	}

	public function testEnglishOnlyNotFlagged(): Void {
		final src: String = 'class C {\n\t// a plain English comment\n\t/** English doc. */\n\tvar x = 1;\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testLatinExtendedNotFlagged(): Void {
		final src: String = 'class C {\n\t// Nöldeke café mañana über straße\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testEmojiArrowsBoxDrawingNotFlagged(): Void {
		final src: String = 'class C {\n\t// \u{1f680} a → b │ ─ ° × « » …\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testCyrillicInStringLiteralNotFlagged(): Void {
		final src: String = 'class C {\n\tvar s = \"привет мир\";\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testMultiWordCyrillicOneFinding(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// это очень длинный\n}');
		Assert.equals(1, vs.length);
	}

	public function testCjkFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// 这是中文注释\n}');
		Assert.equals(1, vs.length);
	}

	public function testPositionAtFirstOffendingChar(): Void {
		final src: String = '// ok текст';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('т', src.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\t// комментарий\n}';
		final check: EnglishComments = new EnglishComments();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('english-comments'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('english-comments'));
	}

	private function violations(src: String): Array<Violation> {
		return new EnglishComments().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
