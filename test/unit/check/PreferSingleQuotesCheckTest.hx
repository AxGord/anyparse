package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferSingleQuotes;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

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

	/**
	 * The escape that spells the trigger. Haxe DECODES `\x24` / `$` / `\u{24}`
	 * before it scans a single-quoted literal for interpolation, so `"\x24a"` — the
	 * text `$a` — prints the VALUE of the local `a` the moment it changes quotes.
	 * Compile-and-run verified on `--interp` and `-js`; the check shipped this
	 * rewrite until the judgement moved to `StringFoldSupport.requoteVerbatim`.
	 */
	public function testEscapedDollarKept(): Void {
		Assert.equals(0, violations('class C { function f() { final a = \"\\x24a\"; } }').length);
		Assert.equals(0, violations('class C { function f() { final a = \"\\u0024a\"; } }').length);
		Assert.equals(0, violations('class C { function f() { final a = \"\\u{24}a\"; } }').length);
		Assert.equals(0, violations('class C { function f() { final a = \"\\x24{a}\"; } }').length);
	}

	/** Only the TRIGGER is refused: `\x41` is an `A` and the swap keeps it verbatim. */
	public function testNonTriggerEscapeConverted(): Void {
		Assert.equals("'\\x41b'", singleOf('class C { function f() { final a = "\\x41b"; } }'));
	}

	/**
	 * An ESCAPED apostrophe is not a terminator: `\'` means `'` under both quotings, so
	 * only a RAW one closes the single-quoted form (`testApostropheKept`). The old
	 * character blacklist could not tell the two apart and refused both — this is the
	 * one WIDENING the seam brings.
	 *
	 * The `\x27` spelling was always converted (no `'` byte to blacklist) and is pinned
	 * here as correct rather than lucky: the literal's extent is fixed BEFORE escapes
	 * decode, so a decoded `'` cannot terminate anything. Compile-and-run: `'\x27'` is
	 * the one-character string `'`, on `--interp` and `-js`.
	 */
	public function testEscapedApostropheConverted(): Void {
		Assert.equals("'it\\'s'", singleOf('class C { function f() { final a = "it\\\'s"; } }'));
		Assert.equals("'it\\x27s'", singleOf('class C { function f() { final a = "it\\x27s"; } }'));
	}

	public function testSingleQuotedNotFlagged(): Void {
		Assert.equals(0, violations("class C { function f() { final a = 'hi'; } }").length);
	}

	public function testEmptyStringFlagged(): Void {
		Assert.equals("''", singleOf('class C { function f() { final a = \"\"; } }'));
	}

	public function testEscapedQuotePreserved(): Void {
		// Source `"a\"b"` -> `'a\"b'`: the \" escape stays valid inside single quotes.
		Assert.equals("'a\\\"b'", singleOf('class C { function f() { final a = \"a\\\"b\"; } }'));
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

	public function testCheckstyleDoublePolicyDisables(): Void {
		// A checkstyle.json StringLiteral policy of double quotes disables "prefer single".
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = tmp != null && tmp.length > 0 ? tmp : '/tmp';
		final dir: String = '$base/anyparse_psq_cs_${Sys.time()}';
		FileSystem.createDirectory(dir);
		File.saveContent('$dir/checkstyle.json', '{"checks":[{"type":"StringLiteral","props":{"policy":"onlyDouble"}}]}');
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tfunction f() { var s = "hi"; return s; }\n}';
		File.saveContent(path, src);
		Assert.equals(0, new PreferSingleQuotes().run([{ file: path, source: src }], new HaxeQueryPlugin()).length);
		FileSystem.deleteFile(path);
		FileSystem.deleteFile('$dir/checkstyle.json');
		FileSystem.deleteDirectory(dir);
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
