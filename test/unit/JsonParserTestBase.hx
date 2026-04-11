package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueTools;

/**
 * Shared test corpus for every JSON parser implementation. Subclasses
 * override `parseJson(source)` with a concrete parser backend; the
 * test methods compare the parsed AST against a curated expected
 * value with `JValueTools.equals`.
 *
 * This is how parity between the hand-written `JsonParser` and the
 * macro-generated `JValueFastParser` is enforced: both backends run
 * the same method bodies, and both must pass.
 */
abstract class JsonParserTestBase extends Test {

	abstract private function parseJson(source:String):JValue;

	private function parseEq(input:String, expected:JValue):Void {
		final actual:JValue = parseJson(input);
		Assert.isTrue(JValueTools.equals(expected, actual),
			'parse of <$input> gave $actual, expected $expected');
	}

	public function testNull() {
		parseEq('null', JNull);
	}

	public function testTrue() {
		parseEq('true', JBool(true));
	}

	public function testFalse() {
		parseEq('false', JBool(false));
	}

	public function testPositiveInt() {
		parseEq('42', JNumber(42));
	}

	public function testNegativeInt() {
		parseEq('-7', JNumber(-7));
	}

	public function testZero() {
		parseEq('0', JNumber(0));
	}

	public function testFloat() {
		parseEq('3.14', JNumber(3.14));
		parseEq('-3.14', JNumber(-3.14));
	}

	public function testScientific() {
		parseEq('1e10', JNumber(1e10));
		parseEq('1.5e-3', JNumber(1.5e-3));
		parseEq('2.5E+2', JNumber(2.5e2));
	}

	public function testEmptyString() {
		parseEq('""', JString(''));
	}

	public function testSimpleString() {
		parseEq('"hello"', JString('hello'));
	}

	public function testStringWithEscapes() {
		parseEq('"a\\nb"', JString('a\nb'));
		parseEq('"\\"quoted\\""', JString('"quoted"'));
		parseEq('"\\\\backslash"', JString('\\backslash'));
		parseEq('"tab\\there"', JString('tab\there'));
	}

	public function testUnicodeEscape() {
		parseEq('"\\u0041"', JString('A'));
	}

	public function testEmptyArray() {
		parseEq('[]', JArray([]));
	}

	public function testArrayOfInts() {
		parseEq('[1, 2, 3]', JArray([JNumber(1), JNumber(2), JNumber(3)]));
	}

	public function testArrayWithWhitespace() {
		parseEq('[\n  1,\n  2\n]', JArray([JNumber(1), JNumber(2)]));
	}

	public function testEmptyObject() {
		parseEq('{}', JObject([]));
	}

	public function testSimpleObject() {
		parseEq('{"x":1}', JObject([{key: 'x', value: JNumber(1)}]));
	}

	public function testObjectMultipleFields() {
		parseEq('{"name":"John","age":30}', JObject([
			{key: 'name', value: JString('John')},
			{key: 'age', value: JNumber(30)},
		]));
	}

	public function testNested() {
		parseEq('{"items":[1,{"x":"y"}]}', JObject([
			{
				key: 'items',
				value: JArray([
					JNumber(1),
					JObject([{key: 'x', value: JString('y')}]),
				]),
			},
		]));
	}

	public function testMixedTypes() {
		parseEq('[null, true, false, 42, "s", [], {}]', JArray([
			JNull, JBool(true), JBool(false), JNumber(42),
			JString('s'), JArray([]), JObject([]),
		]));
	}

	public function testRejectsTrailingData() {
		Assert.raises(() -> parseJson('42 garbage'));
	}

	public function testRejectsUnclosedString() {
		Assert.raises(() -> parseJson('"unclosed'));
	}

	public function testRejectsUnclosedArray() {
		Assert.raises(() -> parseJson('[1, 2'));
	}

	public function testRejectsUnclosedObject() {
		Assert.raises(() -> parseJson('{"x":1'));
	}

	public function testRejectsInvalidNumber() {
		Assert.raises(() -> parseJson('12abc'));
	}
}
