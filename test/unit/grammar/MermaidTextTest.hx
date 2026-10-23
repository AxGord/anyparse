package unit.grammar;

import anyparse.grammar.mermaid.MermaidText;
import haxe.Json;
import utest.Assert;
import utest.Test;

/**
 * `MermaidText` — the label codec every Mermaid label terminal names: entity codes resolve on the
 * way in, a label is written bare when it can be and quoted with entity escapes when it cannot,
 * and every string survives encode-then-decode in every label position.
 */
@:nullSafety(Strict)
class MermaidTextTest extends Test {

	/** Labels that exercise every escape and quoting decision. */
	private static final AWKWARD: Array<String> = [
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
		'`markdown **bold**`',
		'`lead tick',
		'tail tick`',
		'`',
		'``',
		'multi\nline',
		'v1.2-rc=3 -> ok',
		'a;b&c<d>',
		'tab\there',
		'ünïcödé 字'
	];

	/** A quoted label loses its quotes, a bare one its surrounding whitespace, and both resolve entity codes. */
	public function testDecodeStripsQuotesAndResolvesEntities(): Void {
		Assert.equals('say "hi"', MermaidText.decode('"say #quot;hi#quot;"'));
		Assert.equals('a|b', MermaidText.decode('a#124;b'));
		Assert.equals('trimmed', MermaidText.decode('  trimmed \t'));
		Assert.equals(' kept ', MermaidText.decode('" kept "'));
		Assert.equals('<&>\'', MermaidText.decode('#lt;#amp;#gt;#apos;'));
	}

	/** An entity name the codec does not know stays in the text, as Mermaid renders it as an entity too. */
	public function testAnUnknownEntityStaysInTheText(): Void {
		Assert.equals('I #hearts; it', MermaidText.decode('I #hearts; it'));
		Assert.equals('"I #hearts; it"', MermaidText.encode('I #hearts; it'));
	}

	/** A label made of safe characters is written bare. */
	public function testASafeLabelIsWrittenBare(): Void {
		Assert.equals('Start', MermaidText.encode('Start'));
		Assert.equals('Is it ok?', MermaidText.encode('Is it ok?'));
		Assert.equals('v1.2-rc', MermaidText.encode('v1.2-rc'));
	}

	/** A label the bare form cannot hold is quoted, with `"` and an entity-shaped `#` escaped. */
	public function testAnUnsafeLabelIsQuotedAndEscaped(): Void {
		Assert.equals('"a #quot;b#quot;"', MermaidText.encode('a "b"'));
		Assert.equals('"a|b"', MermaidText.encode('a|b'));
		Assert.equals('"#35;quot;"', MermaidText.encode('#quot;'));
		Assert.equals('"issue #12"', MermaidText.encode('issue #12'));
		Assert.equals('""', MermaidText.encode(''));
		Assert.equals('" padded "', MermaidText.encode(' padded '));
	}

	/** A label wrapped in backticks is a markdown string; a stray backtick that would open one is escaped. */
	public function testBackticksFollowTheMarkdownRule(): Void {
		Assert.equals('"`**bold**`"', MermaidText.encode('`**bold**`'));
		Assert.equals('"`a#96;b`"', MermaidText.encode('`a`b`'));
		Assert.equals('"#96;lead"', MermaidText.encode('`lead'));
	}

	/** An inline edge label is quoted when it holds its own link's stroke character, and only then. */
	public function testAnInlineEdgeLabelAvoidsItsStroke(): Void {
		Assert.equals('"pre-check"', MermaidText.encodeSolid('pre-check'));
		Assert.equals('pre-check', MermaidText.encodeThick('pre-check'));
		Assert.equals('"a=b"', MermaidText.encodeThick('a=b'));
		Assert.equals('"v1.2"', MermaidText.encodeDotted('v1.2'));
		Assert.equals('v1.2', MermaidText.encodeSolid('v1.2'));
	}

	/** Every awkward label decodes back to itself through each of the four encoders. */
	public function testEveryLabelRoundTrips(): Void {
		for (label in AWKWARD) {
			Assert.equals(label, MermaidText.decode(MermaidText.encode(label)), 'node: ${Json.stringify(label)}');
			Assert.equals(label, MermaidText.decode(MermaidText.encodeSolid(label)), 'solid: ${Json.stringify(label)}');
			Assert.equals(label, MermaidText.decode(MermaidText.encodeThick(label)), 'thick: ${Json.stringify(label)}');
			Assert.equals(label, MermaidText.decode(MermaidText.encodeDotted(label)), 'dotted: ${Json.stringify(label)}');
		}
	}

}
