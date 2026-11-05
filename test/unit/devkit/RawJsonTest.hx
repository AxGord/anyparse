package unit.devkit;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import devkit.RawJson;
import utest.Assert;
import utest.Test;

/** `devkit.RawJson`: a raw document printed the way `JSON.stringify` prints it, and a key of one read as plain values. */
@:nullSafety(Strict)
final class RawJsonTest extends Test {

	public function testACompactDocumentPrintsWithoutWhitespaceAndAWholeNumberWithoutAFraction(): Void {
		final text: String = '{"a":[1,2.5,"x\\"y",null,true,{},[]],"b":-3}';
		Assert.equals(text, RawJson.print(JValueParser.parse(' { "a" : [1, 2.5, "x\\"y", null, true, {}, []], "b": -3 } ')));
	}

	public function testAnIndentedDocumentPutsEveryEntryOnALineOfItsOwn(): Void {
		final value: JValue = JValueParser.parse('{"k":[1,{"z":false}],"e":{},"n":[]}');
		Assert.equals('{\n  "k": [\n    1,\n    {\n      "z": false\n    }\n  ],\n  "e": {},\n  "n": []\n}', RawJson.print(value, '  '));
		Assert.equals('{\n\t"e": {}\n}', RawJson.print(JValueParser.parse('{"e":{}}'), '\t'));
	}

	public function testAStringIsSpelledWithTheEscapesAnEngineGivesIt(): Void {
		Assert.equals('"a\\nb\\u0001\\\\"', RawJson.print(JString('a\nb\x01\\')));
	}

	public function testAScalarReadsAsTextAndAnythingElseDoesNot(): Void {
		final value: JValue = JValueParser.parse('{"s":"x","n":7,"b":true,"z":null,"a":["p",2,false],"o":{}}');
		Assert.equals('x', RawJson.stringAt(value, 's'));
		Assert.isNull(RawJson.stringAt(value, 'n'));
		Assert.equals('7', RawJson.text(JNumber(7)));
		Assert.equals('true', RawJson.text(JBool(true)));
		Assert.isNull(RawJson.text(JNull));
		Assert.isNull(RawJson.text(JArray([])));
		Assert.isTrue(RawJson.isTrue(JBool(true)));
		Assert.isFalse(RawJson.isTrue(JString('true')));
	}

	public function testOneScalarAndAListBothReadAsAListOfText(): Void {
		Assert.same(['x'], RawJson.strings(JString('x')));
		Assert.same(['p', '2', 'false'], RawJson.strings(JArray([JString('p'), JNumber(2), JBool(false)])));
		Assert.isNull(RawJson.strings(null));
		Assert.isNull(RawJson.strings(JNull));
		Assert.equals(0, RawJson.items(JString('x')).length);
		Assert.equals(2, RawJson.items(JArray([JNull, JNull])).length);
	}

}
