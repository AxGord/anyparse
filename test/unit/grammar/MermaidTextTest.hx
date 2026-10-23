package unit.grammar;

import anyparse.grammar.mermaid.MermaidText;
import haxe.Json;
import utest.Assert;
import utest.Test;

/**
 * `MermaidText` — the label codec every Mermaid label terminal names. A plain label is the text a
 * reader sees, so markup characters are re-escaped on write; a markup label is the HTML Mermaid
 * renders, kept raw; a markdown label is the body of a backtick string. Every value of each kind
 * survives encode-then-decode, and an entity code naming no character stays as written.
 */
@:nullSafety(Strict)
class MermaidTextTest extends Test {

	/** Plain labels that exercise every escape and quoting decision. */
	private static final PLAIN: Array<String> = [
		'plain',
		'two words',
		'',
		' padded ',
		'with "quotes"',
		'a|b',
		'brackets [x] (y) {z}',
		'slash / and back \\',
		'#quot; spelled out',
		'#35;',
		'x #hearts; y',
		'issue #12',
		'`ticks` inside',
		'`lead tick',
		'`',
		'``',
		'multi\nline',
		'v1.2-rc=3 -> ok',
		'a;b&c<d>',
		'Map<String, Int>',
		'<b>not bold</b>',
		'a &quot; b',
		'&#60;',
		'#a_b;',
		'50%% done',
		'tab\there',
		'ünïcödé 字 😀'
	];

	/** Markup values: HTML as Mermaid renders it. */
	private static final MARKUP: Array<String> = [
		'a<br>b',
		'&lt;x&gt;',
		'I &hearts; u',
		'&#99999999;',
		'say "hi"<br>',
		'#lt; literal<i>',
		'`tick`<br>',
		'<b>😀</b>',
		'a<br>&#60;b',
		'x&&#60;y',
		'&a_b;'
	];

	/** A plain label's codes resolve to the characters a reader sees, markup ones included. */
	public function testPlainDecodeResolvesEveryKnownCode(): Void {
		Assert.equals('say "hi"', MermaidText.decodePlain('"say #quot;hi#quot;"'));
		Assert.equals('a|b', MermaidText.decodePlain('a#124;b'));
		Assert.equals('trimmed', MermaidText.decodePlain('  trimmed \t'));
		Assert.equals(' kept ', MermaidText.decodePlain('" kept "'));
		Assert.equals('<&>\'', MermaidText.decodePlain('#lt;#amp;#gt;#apos;'));
	}

	/** A markup label keeps its markup, and a code for `<` `>` `&` or an unknown name becomes the HTML reference. */
	public function testMarkupDecodeKeepsTheHtml(): Void {
		Assert.equals('a<br>b', MermaidText.decodeMarkup('a<br>b'));
		Assert.equals('&lt;b&gt;', MermaidText.decodeMarkup('"#lt;b#gt;"'));
		Assert.equals('I &hearts; "u"', MermaidText.decodeMarkup('"I #hearts; #quot;u#quot;"'));
		Assert.equals('a<br>&#60;b', MermaidText.decodeMarkup('"a<br>#60;b"'));
		Assert.equals('&&#60;', MermaidText.decodeMarkup('"&#60;"'));
	}

	/** A numeric code outside Unicode, or a surrogate, names no character: it stays as written, and nothing throws. */
	@:killer('M-MERMAID-CODEPOINT-UNBOUNDED')
	@:pin('control')
	public function testAnInvalidNumericCodeStaysAsWritten(): Void {
		for (code in ['#99999999;', '#1114112;', '#55357;', '#0;']) Assert.equals(code, MermaidText.decodePlain(code), code);
		Assert.equals('&#1114112;', MermaidText.decodeMarkup('#1114112;'));
	}

	/** Plain text with markup characters is written with codes, so it renders literally. */
	@:killer('M-MERMAID-PLAIN-LT-RAW', 'M-MERMAID-PLAIN-AMP-RAW')
	@:pin('control')
	public function testPlainMarkupCharactersAreEscaped(): Void {
		Assert.equals('"Array#lt;String#gt;"', MermaidText.encodePlain('Array<String>'));
		Assert.equals('"#lt;b#gt;bold#lt;/b#gt;"', MermaidText.encodePlain('<b>bold</b>'));
		Assert.equals('"a #amp;quot; b"', MermaidText.encodePlain('a &quot; b'));
		Assert.equals('"a & b"', MermaidText.encodePlain('a & b'));
	}

	/** A numeric HTML reference in markup is written as Mermaid's code, never raw: Mermaid would turn a raw `&#60;` into `&<`. */
	@:killer('M-MERMAID-NUMERIC-REF-RAW')
	@:pin('control')
	public function testMarkupWritesANumericReferenceAsACode(): Void {
		Assert.equals('"a<br>#60;b"', MermaidText.encodeMarkup('a<br>&#60;b'));
		Assert.equals('"#1114112;"', MermaidText.encodeMarkup('&#1114112;'));
		Assert.equals('"#0;"', MermaidText.encodeMarkup('&#0;'));
		Assert.equals('"x&#60;y"', MermaidText.encodeMarkup('x&&#60;y'));
	}

	/** A code's name is Mermaid's `\w`, so a `_` in it makes a code a plain label must escape. */
	@:killer('M-MERMAID-CODE-ALPHABET-NARROW')
	@:pin('control')
	public function testTheCodeAlphabetIsWordCharacters(): Void {
		Assert.equals('"#35;a_b;"', MermaidText.encodePlain('#a_b;'));
		Assert.equals('&a_b;', MermaidText.decodeMarkup('#a_b;'));
	}

	/** A safe plain label is written bare; one with a delimiter, a quote, an entity-shaped `#` or `%` is quoted. */
	public function testPlainBareOrQuoted(): Void {
		Assert.equals('Is it ok?', MermaidText.encodePlain('Is it ok?'));
		Assert.equals('v1.2-rc', MermaidText.encodePlain('v1.2-rc'));
		Assert.equals('"a #quot;b#quot;"', MermaidText.encodePlain('a "b"'));
		Assert.equals('"#35;quot;"', MermaidText.encodePlain('#quot;'));
		Assert.equals('"50%% done"', MermaidText.encodePlain('50%% done'));
		Assert.equals('""', MermaidText.encodePlain(''));
	}

	/** Backticks in plain text stay literal: bare when they can, and a quoted label never opens a markdown string. */
	@:killer('M-MERMAID-TICK-UNESCAPED')
	@:pin('control')
	public function testPlainBackticksNeverOpenMarkdown(): Void {
		Assert.equals('`x`', MermaidText.encodePlain('`x`'));
		Assert.equals('"#96;x` y|z"', MermaidText.encodePlain('`x` y|z'));
		Assert.equals('"`a#grave;b`"', MermaidText.encodeMarkdown('a`b'));
	}

	/** An inline edge label is quoted when it holds its own link's stroke character, and only then. */
	public function testAnInlineEdgeLabelAvoidsItsStroke(): Void {
		Assert.equals('"pre-check"', MermaidText.encodePlainSolid('pre-check'));
		Assert.equals('pre-check', MermaidText.encodePlainThick('pre-check'));
		Assert.equals('"a=b"', MermaidText.encodePlainThick('a=b'));
		Assert.equals('"v1.2"', MermaidText.encodePlainDotted('v1.2'));
		Assert.equals('v1.2', MermaidText.encodePlainSolid('v1.2'));
	}

	/** Every value of each kind decodes back to itself through every encoder of that kind. */
	public function testEveryLabelRoundTrips(): Void {
		for (text in PLAIN) {
			final shown: String = Json.stringify(text);
			Assert.equals(text, MermaidText.decodePlain(MermaidText.encodePlain(text)), 'plain: $shown');
			Assert.equals(text, MermaidText.decodePlain(MermaidText.encodePlainSolid(text)), 'solid: $shown');
			Assert.equals(text, MermaidText.decodePlain(MermaidText.encodePlainThick(text)), 'thick: $shown');
			Assert.equals(text, MermaidText.decodePlain(MermaidText.encodePlainDotted(text)), 'dotted: $shown');
			Assert.equals(text, MermaidText.decodeMarkdown(MermaidText.encodeMarkdown(text)), 'markdown: $shown');
		}
		for (html in MARKUP)
			Assert.equals(html, MermaidText.decodeMarkup(MermaidText.encodeMarkup(html)), 'markup: ${Json.stringify(html)}');
	}

}
