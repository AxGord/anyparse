package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonWriter;

/**
	Tests for the Doc-based JSON writer. Checks specific formatting
	decisions (flat vs broken, spacing, escape sequences) independent of
	the parser.
**/
class JsonWriterTest extends Test {
	function testWritePrimitives() {
		Assert.equals("null", JsonWriter.write(JNull));
		Assert.equals("true", JsonWriter.write(JBool(true)));
		Assert.equals("false", JsonWriter.write(JBool(false)));
		Assert.equals("42", JsonWriter.write(JNumber(42)));
		Assert.equals("-7", JsonWriter.write(JNumber(-7)));
		Assert.equals("0", JsonWriter.write(JNumber(0)));
		Assert.equals('"hello"', JsonWriter.write(JString("hello")));
		Assert.equals('""', JsonWriter.write(JString("")));
	}

	function testWriteEmptyContainers() {
		Assert.equals("[]", JsonWriter.write(JArray([])));
		Assert.equals("{}", JsonWriter.write(JObject([])));
	}

	function testWriteSmallArrayFlat() {
		var ast = JArray([JNumber(1), JNumber(2), JNumber(3)]);
		Assert.equals("[1, 2, 3]", JsonWriter.write(ast));
	}

	function testWriteSmallObjectFlat() {
		var ast = JObject([
			{key: "a", value: JNumber(1)},
			{key: "b", value: JNumber(2)},
		]);
		Assert.equals('{"a": 1, "b": 2}', JsonWriter.write(ast));
	}

	function testWriteLongArrayBroken() {
		// Construct an array long enough to overflow the default 80-col width.
		var items = [for (i in 0...20) JNumber(1234567890)];
		var out = JsonWriter.write(JArray(items));
		// Expect a break at the outer array.
		Assert.isTrue(out.indexOf("\n") >= 0, 'expected break in output: $out');
		// Each number should be indented with two spaces.
		Assert.isTrue(out.indexOf("\n  1234567890") >= 0, 'expected indented item in: $out');
	}

	function testCompactOptions() {
		var ast = JObject([
			{key: "a", value: JNumber(1)},
			{key: "b", value: JArray([JNumber(2), JNumber(3)])},
		]);
		Assert.equals('{"a":1,"b":[2,3]}', JsonWriter.write(ast, {
			indent: "",
			lineWidth: 1000,
			spaceAfterColon: false,
		}));
	}

	function testWriteEscapedString() {
		Assert.equals('"line1\\nline2"', JsonWriter.write(JString("line1\nline2")));
		Assert.equals('"has \\"quotes\\""', JsonWriter.write(JString('has "quotes"')));
		Assert.equals('"back\\\\slash"', JsonWriter.write(JString("back\\slash")));
		Assert.equals('"tab\\there"', JsonWriter.write(JString("tab\there")));
	}

	function testNestedStructureFlat() {
		var ast = JObject([
			{key: "x", value: JArray([JNumber(1), JNumber(2)])},
			{key: "y", value: JBool(true)},
		]);
		Assert.equals('{"x": [1, 2], "y": true}', JsonWriter.write(ast));
	}
}
