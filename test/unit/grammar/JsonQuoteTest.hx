package unit.grammar;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JsonFormat;
import utest.Assert;
import utest.Test;

/**
 * `JsonFormat.quote` writes the bytes a native JSON writer writes, and `compactWriteOptions` keeps a document on one line
 * and still readable.
 */
class JsonQuoteTest extends Test {

	public function testEscapes(): Void {
		Assert.equals('"a\\"b\\\\c\\n\\r\\t\\b\\f"', JsonFormat.instance.quote('a"b\\c\n\r\t\x08\x0C'));
	}

	public function testAControlCharacterIsInLowerCase(): Void {
		Assert.equals('"\\u0001\\u001f"', JsonFormat.instance.quote('\x01\x1f'));
		Assert.equals('"\\u001f"', JValueWriter.write(JString('\x1f')));
	}

	public function testAnythingElseStaysAsItIs(): Void {
		Assert.equals('"é😀\x7f/"', JsonFormat.instance.quote('é😀\x7f/'));
	}

	@:pin('control') @:killer('M-JSON-QUOTE-LONE-SURROGATE')
	public function testALoneSurrogateKeepsItsEscape(): Void {
		final high: String = String.fromCharCode(0xD83D);
		final low: String = String.fromCharCode(0xDE00);
		Assert.equals('"\\ud83dx"', JsonFormat.instance.quote('${high}x'));
		Assert.equals('"x\\ude00"', JsonFormat.instance.quote('x$low'));
		Assert.equals('"\\ud83d"', JsonFormat.instance.quote(high));
		Assert.equals('"\\ude00\\ud83d"', JsonFormat.instance.quote(low + high));
		Assert.equals('"$high$low"', JsonFormat.instance.quote(high + low));
	}

	/** Where a generated writer parts from `quote`: its per-character escape never sees the other half of a pair. */
	public function testAGeneratedWriterWritesALoneSurrogateBare(): Void {
		final high: String = String.fromCharCode(0xD83D);
		Assert.equals('"$high"', JValueWriter.write(JString(high)));
	}

	public function testAQuotedStringReadsBack(): Void {
		final text: String = 'a"b\\c\n\x01é😀';
		Assert.isTrue(JValueTools.equals(JString(text), JValueParser.parse(JsonFormat.instance.quote(text))));
	}

	public function testACompactDocumentIsOneLineAndReadsBack(): Void {
		final document: JValue = JObject([
			for (i in 0...2000) JValueTools.entry('key$i', JArray([JString('value $i'), JObject([JValueTools.entry('n', JNumber(i))])]))
		]);
		final compact: String = JValueWriter.write(document, JsonFormat.instance.compactWriteOptions);
		Assert.equals(-1, compact.indexOf('\n'));
		Assert.isTrue(JValueTools.equals(document, JValueParser.parse(compact)));
		Assert.isTrue(JValueWriter.write(document, JsonFormat.instance.defaultWriteOptions).length > compact.length);
	}

	public function testTheDefaultWidthStands(): Void {
		Assert.equals(120, JsonFormat.instance.defaultWriteOptions.lineWidth);
	}

}
