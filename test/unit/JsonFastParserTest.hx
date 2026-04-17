package unit;

import utest.Assert;
import utest.Test;
// Importing JValue first ensures its `@:build` macro has run before the
// compiler tries to resolve `JValueFastParser` below — the latter is
// contributed by the macro rather than existing as a source file.
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueFastParser;
import anyparse.grammar.json.JValueTools;

/**
 * JSON parser corpus against the macro-generated `JValueFastParser`.
 *
 * The only JSON parser in the project — there is no hand-written
 * reference any more. Every assertion below both locks the macro
 * pipeline's current behaviour and doubles as a regression anchor
 * for the slice decisions captured in `docs/roadmap.md`.
 */
@:nullSafety(Strict)
class JsonFastParserTest extends Test {

	public function new():Void {
		super();
	}

	private function parseEq(input:String, expected:JValue):Void {
		final actual:JValue = JValueFastParser.parse(input);
		Assert.isTrue(JValueTools.equals(expected, actual),
			'parse of <$input> gave $actual, expected $expected');
	}

	public function testNull():Void {
		parseEq('null', JNull);
	}

	public function testTrue():Void {
		parseEq('true', JBool(true));
	}

	public function testFalse():Void {
		parseEq('false', JBool(false));
	}

	public function testPositiveInt():Void {
		parseEq('42', JNumber(42));
	}

	public function testNegativeInt():Void {
		parseEq('-7', JNumber(-7));
	}

	public function testZero():Void {
		parseEq('0', JNumber(0));
	}

	public function testFloat():Void {
		parseEq('3.14', JNumber(3.14));
		parseEq('-3.14', JNumber(-3.14));
	}

	public function testScientific():Void {
		parseEq('1e10', JNumber(1e10));
		parseEq('1.5e-3', JNumber(1.5e-3));
		parseEq('2.5E+2', JNumber(2.5e2));
	}

	public function testEmptyString():Void {
		parseEq('""', JString(''));
	}

	public function testSimpleString():Void {
		parseEq('"hello"', JString('hello'));
	}

	public function testStringWithEscapes():Void {
		parseEq('"a\\nb"', JString('a\nb'));
		parseEq('"\\"quoted\\""', JString('"quoted"'));
		parseEq('"\\\\backslash"', JString('\\backslash'));
		parseEq('"tab\\there"', JString('tab\there'));
	}

	public function testUnicodeEscape():Void {
		parseEq('"\\u0041"', JString('A'));
	}

	public function testEmptyArray():Void {
		parseEq('[]', JArray([]));
	}

	public function testArrayOfInts():Void {
		parseEq('[1, 2, 3]', JArray([JNumber(1), JNumber(2), JNumber(3)]));
	}

	public function testArrayWithWhitespace():Void {
		parseEq('[\n  1,\n  2\n]', JArray([JNumber(1), JNumber(2)]));
	}

	public function testEmptyObject():Void {
		parseEq('{}', JObject([]));
	}

	public function testSimpleObject():Void {
		parseEq('{"x":1}', JObject([{key: 'x', value: JNumber(1)}]));
	}

	public function testObjectMultipleFields():Void {
		parseEq('{"name":"John","age":30}', JObject([
			{key: 'name', value: JString('John')},
			{key: 'age', value: JNumber(30)},
		]));
	}

	public function testNested():Void {
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

	public function testMixedTypes():Void {
		parseEq('[null, true, false, 42, "s", [], {}]', JArray([
			JNull, JBool(true), JBool(false), JNumber(42),
			JString('s'), JArray([]), JObject([]),
		]));
	}

	public function testRejectsTrailingData():Void {
		Assert.raises(() -> JValueFastParser.parse('42 garbage'));
	}

	public function testRejectsUnclosedString():Void {
		Assert.raises(() -> JValueFastParser.parse('"unclosed'));
	}

	public function testRejectsUnclosedArray():Void {
		Assert.raises(() -> JValueFastParser.parse('[1, 2'));
	}

	public function testRejectsUnclosedObject():Void {
		Assert.raises(() -> JValueFastParser.parse('{"x":1'));
	}

	public function testRejectsInvalidNumber():Void {
		Assert.raises(() -> JValueFastParser.parse('12abc'));
	}
}
