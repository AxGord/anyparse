package unit.grammar.json;

import anyparse.format.WriteOptions;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JsonFormat;
import utest.Assert;
import utest.Test;

/** A document holding a lone surrogate reads back as that character from every layout `JValueWriter` writes, not as a bare unit. */
@:nullSafety(Strict)
final class JValueLoneSurrogateTest extends Test {

	@:killer('M-STRING-ENCODER-UNUSED')
	@:pin('control')
	public function testADocumentHoldingALoneSurrogateEscapeWritesTheEscapeBackUnderEveryLayout(): Void {
		final escaped: String = '"\\ud83d"';
		final value: JValue = JValueParser.parse(escaped);
		final layouts: Array<WriteOptions> = [
			JsonFormat.instance.compactWriteOptions,
			JsonFormat.instance.expandedWriteOptions,
			JsonFormat.instance.tabbedWriteOptions
		];
		for (options in layouts) Assert.equals(escaped, JValueWriter.write(value, options));
	}

	public function testAValidPairStaysBareWhereALoneHalfIsEscaped(): Void {
		final pair: String = String.fromCharCode(0xD83D) + String.fromCharCode(0xDE00);
		final text: String = '["$pair","\\ude00"]';
		final out: String = JValueWriter.write(JValueParser.parse(text), JsonFormat.instance.compactWriteOptions);
		Assert.equals(text, out);
	}

}
