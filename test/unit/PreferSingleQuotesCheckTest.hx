package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferSingleQuotes;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `prefer-single-quotes` check: a double-quoted string literal with no `$`
 * (interpolation) and no `'` is flagged (`Info`) and rewritten to single quotes;
 * a literal containing `$` or `'`, and any single-quoted literal, is left alone.
 * Escapes (`\"`, ...) are preserved verbatim across the swap. The fix's text is
 * asserted directly plus one applied round-trip through `canonicalize`.
 */
class PreferSingleQuotesCheckTest extends Test {

	public function testDoubleQuotedFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f() { final a = "hi"; } }');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-single-quotes', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixSwapsToSingle(): Void {
		Assert.equals("'hi'", singleOf('class C { function f() { final a = "hi"; } }'));
	}

	public function testDollarKept(): Void {
		// Double quotes deliberately suppress interpolation — converting would interpolate $x.
		Assert.equals(0, violations("class C { function f() { final a = \"id=$x\"; } }").length);
	}

	public function testApostropheKept(): Void {
		// A raw ' in the content would terminate the single-quoted form.
		Assert.equals(0, violations("class C { function f() { final a = \"it's\"; } }").length);
	}

	public function testSingleQuotedNotFlagged(): Void {
		Assert.equals(0, violations("class C { function f() { final a = 'hi'; } }").length);
	}

	public function testEmptyStringFlagged(): Void {
		Assert.equals("''", singleOf("class C { function f() { final a = \"\"; } }"));
	}

	public function testEscapedQuotePreserved(): Void {
		// Source `"a\"b"` -> `'a\"b'`: the \" escape stays valid inside single quotes.
		Assert.equals("'a\\\"b'", singleOf("class C { function f() { final a = \"a\\\"b\"; } }"));
	}

	public function testMultipleFlagged(): Void {
		Assert.equals(2, violations('class C { function f() { final a = "x"; final b = "y"; } }').length);
	}

	public function testFixAppliedResult(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = "hi";\n\t}\n}';
		final check: PreferSingleQuotes = new PreferSingleQuotes();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.contains("'hi'"));
				Assert.isFalse(text.contains('"hi"'));
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-single-quotes'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-single-quotes'));
	}

	private function violations(src: String): Array<Violation> {
		return new PreferSingleQuotes().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The single-quoted text the fix emits for `src`'s first convertible literal (empty if none). */
	private function singleOf(src: String): String {
		final check: PreferSingleQuotes = new PreferSingleQuotes();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
	}

}
