package unit.grammar;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import utest.Assert;
import utest.Test;

/** `JValueTools.at` walks a dotted path of keys and array indexes, reading each key the way `field` reads it. */
class JValueToolsAtTest extends Test {

	private static final DOCUMENT: String = '{"a": [{"b": "x"}, 2, null], "c": {"d": true}}';

	public function testAPathOfKeysAndIndexesReadsTheValueAtItsEnd(): Void {
		final value: JValue = JValueParser.parse(DOCUMENT);
		Assert.isTrue(JValueTools.equals(JString('x'), held(JValueTools.at(value, 'a.0.b'))));
		Assert.isTrue(JValueTools.equals(JNumber(2), held(JValueTools.at(value, 'a.1'))));
		Assert.isTrue(JValueTools.equals(JBool(true), held(JValueTools.at(value, 'c.d'))));
	}

	public function testAnEmptyPathIsTheValueItself(): Void {
		final value: JValue = JValueParser.parse(DOCUMENT);
		Assert.isTrue(JValueTools.equals(value, held(JValueTools.at(value, ''))));
	}

	public function testAStepThatFindsNothingIsNull(): Void {
		final value: JValue = JValueParser.parse(DOCUMENT);
		Assert.isNull(JValueTools.at(value, 'a.3'), 'past the end');
		Assert.isNull(JValueTools.at(value, 'a.2'), 'a null element reads as absent');
		Assert.isNull(JValueTools.at(value, 'a.b'), 'a key of an array');
		Assert.isNull(JValueTools.at(value, 'c.d.e'), 'past a scalar');
		Assert.isNull(JValueTools.at(value, 'a.-1'), 'a negative index');
		Assert.isNull(JValueTools.at(null, 'a'));
	}

	@:pin('control') @:killer('M-JVALUE-AT-LOOSE-INDEX')
	public function testAnIndexIsTheWholeSegment(): Void {
		Assert.isNull(JValueTools.at(JValueParser.parse('[1, 2]'), '1x'), 'a segment a number only starts is no index');
		Assert.isNull(JValueTools.at(JValueParser.parse('[1, 2]'), '01'), 'nor one spelled with a leading zero');
	}

	private static function held(value: Null<JValue>): JValue {
		return value ?? JString('absent');
	}

}
