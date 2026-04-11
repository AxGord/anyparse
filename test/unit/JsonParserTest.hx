package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonParser;

/**
	Tests for the hand-written JSON parser. These are unit tests for
	specific constructs, independent of the writer (which is exercised by
	round-trip tests).
**/
class JsonParserTest extends Test {
	inline function parseEq(input:String, expected:JValue):Void {
		var actual = JsonParser.parse(input);
		Assert.isTrue(JValueTools.equals(expected, actual),
			'parse of <$input> gave $actual, expected $expected');
	}

	function testNull() {
		parseEq("null", JNull);
	}

	function testTrue() {
		parseEq("true", JBool(true));
	}

	function testFalse() {
		parseEq("false", JBool(false));
	}

	function testPositiveInt() {
		parseEq("42", JNumber(42));
	}

	function testNegativeInt() {
		parseEq("-7", JNumber(-7));
	}

	function testZero() {
		parseEq("0", JNumber(0));
	}

	function testFloat() {
		parseEq("3.14", JNumber(3.14));
		parseEq("-3.14", JNumber(-3.14));
	}

	function testScientific() {
		parseEq("1e10", JNumber(1e10));
		parseEq("1.5e-3", JNumber(1.5e-3));
		parseEq("2.5E+2", JNumber(2.5e2));
	}

	function testEmptyString() {
		parseEq('""', JString(""));
	}

	function testSimpleString() {
		parseEq('"hello"', JString("hello"));
	}

	function testStringWithEscapes() {
		parseEq('"a\\nb"', JString("a\nb"));
		parseEq('"\\\"quoted\\\""', JString('"quoted"'));
		parseEq('"\\\\backslash"', JString("\\backslash"));
		parseEq('"tab\\there"', JString("tab\there"));
	}

	function testUnicodeEscape() {
		parseEq('"\\u0041"', JString("A"));
	}

	function testEmptyArray() {
		parseEq("[]", JArray([]));
	}

	function testArrayOfInts() {
		parseEq("[1, 2, 3]", JArray([JNumber(1), JNumber(2), JNumber(3)]));
	}

	function testArrayWithWhitespace() {
		parseEq("[\n  1,\n  2\n]", JArray([JNumber(1), JNumber(2)]));
	}

	function testEmptyObject() {
		parseEq("{}", JObject([]));
	}

	function testSimpleObject() {
		parseEq('{"x":1}', JObject([{key: "x", value: JNumber(1)}]));
	}

	function testObjectMultipleFields() {
		parseEq('{"name":"John","age":30}', JObject([
			{key: "name", value: JString("John")},
			{key: "age", value: JNumber(30)},
		]));
	}

	function testNested() {
		parseEq('{"items":[1,{"x":"y"}]}', JObject([
			{
				key: "items",
				value: JArray([
					JNumber(1),
					JObject([{key: "x", value: JString("y")}]),
				]),
			},
		]));
	}

	function testMixedTypes() {
		parseEq('[null, true, false, 42, "s", [], {}]', JArray([
			JNull, JBool(true), JBool(false), JNumber(42),
			JString("s"), JArray([]), JObject([]),
		]));
	}

	function testRejectsTrailingData() {
		Assert.raises(() -> JsonParser.parse("42 garbage"));
	}

	function testRejectsUnclosedString() {
		Assert.raises(() -> JsonParser.parse('"unclosed'));
	}

	function testRejectsUnclosedArray() {
		Assert.raises(() -> JsonParser.parse("[1, 2"));
	}

	function testRejectsUnclosedObject() {
		Assert.raises(() -> JsonParser.parse('{"x":1'));
	}

	function testRejectsInvalidNumber() {
		Assert.raises(() -> JsonParser.parse("12abc"));
	}
}
