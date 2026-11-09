package unit.grammar.json;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JsonFormat;
import utest.Assert;
import utest.Test;

/** A raw document written by `JValueWriter` in the bytes `JSON.stringify` gives it, and a key of one read through `JValueTools`. */
@:nullSafety(Strict)
final class JValueDocumentTest extends Test {

	public function testACompactDocumentPrintsWithoutWhitespaceAndAWholeNumberWithoutAFraction(): Void {
		final text: String = '{"a":[1,2.5,"x\\"y",null,true,{},[]],"b":-3}';
		final value: JValue = JValueParser.parse(' { "a" : [1, 2.5, "x\\"y", null, true, {}, []], "b": -3 } ');
		Assert.equals(text, JValueWriter.write(value, JsonFormat.instance.compactWriteOptions));
	}

	public function testAnExpandedDocumentPutsEveryEntryOnALineOfItsOwn(): Void {
		final value: JValue = JValueParser.parse('{"k":[1,{"z":false}],"e":{},"n":[]}');
		Assert.equals(
			'{\n  "k": [\n    1,\n    {\n      "z": false\n    }\n  ],\n  "e": {},\n  "n": []\n}',
			JValueWriter.write(value, JsonFormat.instance.expandedWriteOptions)
		);
	}

	@:pin('control') @:killer('M-TABBED-OPTIONS-SPACES')
	public function testATabbedDocumentIndentsEachLevelByOneTab(): Void {
		final value: JValue = JValueParser.parse('{"e":{"a":[1]},"o":{}}');
		Assert.equals(
			'{\n\t"e": {\n\t\t"a": [\n\t\t\t1\n\t\t]\n\t},\n\t"o": {}\n}',
			JValueWriter.write(value, JsonFormat.instance.tabbedWriteOptions)
		);
	}

	public function testAStringIsSpelledWithTheEscapesAnEngineGivesIt(): Void {
		Assert.equals('"a\\nb\\u0001\\\\"', JValueWriter.write(JString('a\nb\x01\\'), JsonFormat.instance.compactWriteOptions));
		Assert.equals('"a\\nb\\u0001\\\\"', JValueWriter.write(JString('a\nb\x01\\'), JsonFormat.instance.expandedWriteOptions));
	}

	public function testALoneSurrogateIsTheOneByteTheDocWriterSpellsApartFromQuote(): Void {
		final lone: String = String.fromCharCode(0xD83D);
		Assert.equals('"\\ud83d"', JsonFormat.instance.quote(lone));
		Assert.equals('"$lone"', JValueWriter.write(JString(lone), JsonFormat.instance.expandedWriteOptions));
		Assert.equals('"$lone"', JValueWriter.write(JValueParser.parse('"\\ud83d"'), JsonFormat.instance.expandedWriteOptions));
	}

	public function testAScalarReadsAsTextAndAnythingElseDoesNot(): Void {
		final value: JValue = JValueParser.parse('{"s":"x","n":7,"b":true,"z":null,"a":["p",2,false],"o":{}}');
		Assert.equals('x', JValueTools.stringAt(value, 's'));
		Assert.isNull(JValueTools.stringAt(value, 'n'));
		Assert.equals('7', JValueTools.text(JNumber(7)));
		Assert.equals('true', JValueTools.text(JBool(true)));
		Assert.isNull(JValueTools.text(JNull));
		Assert.isNull(JValueTools.text(JArray([])));
		Assert.isTrue(JValueTools.isTrue(JBool(true)));
		Assert.isFalse(JValueTools.isTrue(JString('true')));
	}

	public function testOneScalarAndAListBothReadAsAListOfText(): Void {
		Assert.same(['x'], JValueTools.strings(JString('x')));
		Assert.same(['p', '2', 'false'], JValueTools.strings(JArray([JString('p'), JNumber(2), JBool(false)])));
		Assert.isNull(JValueTools.strings(null));
		Assert.isNull(JValueTools.strings(JNull));
		Assert.equals(0, JValueTools.items(JString('x')).length);
		Assert.equals(2, JValueTools.items(JArray([JNull, JNull])).length);
	}

}
