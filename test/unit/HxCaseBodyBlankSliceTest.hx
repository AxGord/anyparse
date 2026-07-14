package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * ω-nestbody-blank — a `switch` case / default body preserves a source
 * blank line between two consecutive statements.
 *
 * The `@:fmt(nestBody)` Star path (`HxCaseBranch.body` /
 * `HxDefaultBranch.stmts`) previously emitted a bare hardline between
 * body statements, dropping any authored blank line — unlike a function
 * block, which keeps it. haxe-formatter keeps inter-statement blanks in
 * case / default bodies too. The fix mirrors the sibling
 * `_t.newlineBefore` branch's cascade-blanks loop, gated on `_si > 0`
 * so the FIRST body statement still hugs `case X:` / `default:` with no
 * leading blank.
 */
@:nullSafety(Strict)
class HxCaseBodyBlankSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testCaseBodyKeepsInterStatementBlank(): Void {
		final out: String = write('class C { function f() { switch (x) { case 1: var a = 1;\n\n doThing(a); default: noop(); } } }');
		Assert.isTrue(out.indexOf('var a = 1;\n\n') != -1, 'case body must keep the blank between its statements: <$out>');
	}

	public function testDefaultBodyKeepsInterStatementBlank(): Void {
		final out: String = write('class C { function f() { switch (x) { case 1: single(); default: noop();\n\n done(); } } }');
		Assert.isTrue(out.indexOf('noop();\n\n') != -1, 'default body must keep the blank between its statements: <$out>');
	}

	public function testCaseBodyDropsLeadingBlank(): Void {
		final out: String = write('class C { function f() { switch (x) { case 1:\n\n first(); second(); default: noop(); } } }');
		Assert.isTrue(out.indexOf('case 1:\n\n') == -1, 'the first case-body statement must not gain a leading blank: <$out>');
	}

	public function testSingleStatementCaseGainsNoBlank(): Void {
		final out: String = write('class C { function f() { switch (x) { case 1: only(); default: noop(); } } }');
		Assert.isTrue(out.indexOf('only();') != -1, 'the single case statement is emitted: <$out>');
		Assert.isTrue(out.indexOf('\n\n') == -1, 'a single-statement case body must not introduce any blank line: <$out>');
	}

	private function write(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson('{}'));
	}

}
