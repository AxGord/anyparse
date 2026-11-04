package unit.grammar;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import utest.Assert;
import utest.Test;

/** `JValueTools.field` reads a key the way a schema reads one: `null` is absent, and the last of two spellings wins. */
class JValueToolsFieldTest extends Test {

	public function testAKeyReadsItsValue(): Void {
		Assert.isTrue(JValueTools.equals(JNumber(1), held(JValueTools.field(JValueParser.parse('{"a": 1}'), 'a'))));
	}

	public function testAnAbsentKeyAndANonObjectAreNull(): Void {
		Assert.isNull(JValueTools.field(JValueParser.parse('{"a": 1}'), 'b'));
		Assert.isNull(JValueTools.field(JValueParser.parse('[1]'), 'a'));
		Assert.isNull(JValueTools.field(JValueParser.parse('"a"'), 'a'));
		Assert.isNull(JValueTools.field(null, 'a'));
	}

	@:pin('control') @:killer('M-JVALUE-FIELD-NULL-HELD')
	public function testAKeyHoldingNullIsAbsent(): Void {
		Assert.isNull(JValueTools.field(JValueParser.parse('{"a": null}'), 'a'));
	}

	public function testTheLastSpellingWins(): Void {
		Assert.isTrue(JValueTools.equals(JNumber(2), held(JValueTools.field(JValueParser.parse('{"a": 1, "a": 2}'), 'a'))));
		Assert.isNull(JValueTools.field(JValueParser.parse('{"a": 1, "a": null}'), 'a'));
	}

	private static function held(value: Null<JValue>): JValue {
		return value ?? JString('absent');
	}

}
