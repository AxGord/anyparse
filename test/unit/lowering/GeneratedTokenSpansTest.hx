package unit.lowering;

import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.TokenSpans;
import unit.minilex.MiniLexScan;

/**
 * The token reader `Build.buildLexicalScan` generates beside the region walk, asked for each grammar what only
 * its own declarations can answer: which literal texts it spells, which terminals it tags `@:token(<Kind>)`, and
 * which regions it reads as one token.
 *
 * `MiniLexScan` is the second grammar: its literals are `(` / `)` and its directive keywords, its word is
 * `[a-z]+`, its regions `@ … @` and `<# … #>`. A Haxe `[` is nothing there, so a reader that knew Haxe's
 * punctuation would answer it; this one reads it as an `Unknown` character.
 */
@:nullSafety(Strict)
final class GeneratedTokenSpansTest extends Test {

	/** MiniLex's own literals, word, string and comment are its tokens; Haxe's brackets are unknown characters. */
	@:pin('control')
	@:killer('M-TOKEN-LITERALS-NONE')
	public function testTheSecondGrammarTokenizesByItsOwnDeclarations(): Void {
		final source: String = '%when (word @a b@ <# c #>) [x]';
		final spans: Array<TokenSpan> = MiniLexScan.tokens(source, 0, source.length);
		Assert.same(['%when', '(', 'word', '@a b@', '<# c #>', ')', '[', 'x', ']'], TokenSpans.texts(source, spans));
		Assert.same(([Literal, Literal, Word, Region, Region, Literal, Unknown, Word, Unknown]: Array<TokenKind>), kindsOf(spans));
	}

	/** Haxe `trace([])` reads as the word and the four brackets the grammar declares, through the plugin seam. */
	@:pin('control')
	@:killer('M-TOKEN-TERMINALS-NONE')
	public function testHaxeTraceCallTokenizesToItsWordAndBrackets(): Void {
		final source: String = 'trace([])';
		final spans: Array<TokenSpan> = new HaxeQueryPlugin().tokenSpans(source, 0, source.length);
		Assert.same(['trace', '(', '[', ']', ')'], TokenSpans.texts(source, spans));
		Assert.same(([Word, Literal, Literal, Literal, Literal]: Array<TokenKind>), kindsOf(spans));
	}

	/** A string literal and a comment are one token each, by the same walks the region scan runs. */
	@:pin('control')
	@:killer('M-TOKEN-REGIONS-NONE')
	public function testARegionIsOneToken(): Void {
		final source: String = 'f("a b", /* c */ 1)';
		final spans: Array<TokenSpan> = new HaxeQueryPlugin().tokenSpans(source, 0, source.length);
		Assert.same(['f', '(', '"a b"', ',', '/* c */', '1', ')'], TokenSpans.texts(source, spans));
		Assert.same(([Word, Literal, Region, Literal, Region, Number, Literal]: Array<TokenKind>), kindsOf(spans));
	}

	/** The longest match wins, and a keyword the word pattern matches equally long reads as the keyword. */
	@:pin('control')
	@:killer('M-TOKEN-TIE-TO-TERMINAL')
	public function testTheLongestMatchWinsAndATieGoesToTheLiteral(): Void {
		final source: String = 'new newer 0x1F 1.5e3 >>>=';
		final spans: Array<TokenSpan> = new HaxeQueryPlugin().tokenSpans(source, 0, source.length);
		Assert.same(['new', 'newer', '0x1F', '1.5e3', '>>>='], TokenSpans.texts(source, spans));
		Assert.same(([Literal, Word, Number, Number, Literal]: Array<TokenKind>), kindsOf(spans));
	}

	/** Only a token starting inside `[from, to)` is reported, at its full extent. */
	public function testOnlyTokensStartingInTheRangeAreReported(): Void {
		final source: String = 'alpha beta gamma';
		Assert.same(['beta'], TokenSpans.texts(source, MiniLexScan.tokens(source, 5, 8)));
	}

	/** A grammar that declares no token reader answers empty. */
	public function testAGrammarWithoutAReaderAnswersEmpty(): Void {
		Assert.equals(0, new JsonQueryPlugin().tokenSpans('{"a": 1}', 0, 8).length);
	}

	/** The kind of every span of `spans`, in order. */
	private static function kindsOf(spans: Array<TokenSpan>): Array<TokenKind> {
		return spans.map(span -> span.kind);
	}

}
