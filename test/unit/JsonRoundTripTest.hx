package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonParser;
import anyparse.grammar.json.JsonWriter;

/**
	Round-trip tests: `parse(write(ast)) == ast` for a curated set of
	interesting cases plus a seeded random generator.

	This is the first property-based test in the project. When we add the
	macro-generated parser and writer, this same test suite should pass
	unchanged — round-trip equivalence is the invariant.
**/
class JsonRoundTripTest extends Test {
	function roundTrip(ast:JValue, ?label:String):Void {
		var written = JsonWriter.write(ast);
		var reparsed:JValue;
		try {
			reparsed = JsonParser.parse(written);
		} catch (e:Dynamic) {
			Assert.fail('parse failed for ${label != null ? label : "case"}: written=<$written>, err=$e');
			return;
		}
		Assert.isTrue(JValueTools.equals(ast, reparsed),
			'round-trip failed for ${label != null ? label : Std.string(ast)}: written=<$written>, reparsed=$reparsed');
	}

	function testCuratedCases() {
		var cases:Array<JValue> = [
			JNull,
			JBool(true),
			JBool(false),
			JNumber(0),
			JNumber(1),
			JNumber(-1),
			JNumber(42),
			JNumber(3.14),
			JNumber(-3.14),
			JNumber(1e10),
			JString(""),
			JString("hello"),
			JString("with\nnewline"),
			JString('has "quotes"'),
			JString("back\\slash"),
			JString("tab\there"),
			JArray([]),
			JArray([JNull]),
			JArray([JBool(true), JBool(false)]),
			JArray([JNumber(1), JNumber(2), JNumber(3)]),
			JArray([JString("a"), JString("b"), JString("c")]),
			JObject([]),
			JObject([{key: "x", value: JNumber(1)}]),
			JObject([
				{key: "name", value: JString("John")},
				{key: "age", value: JNumber(30)},
				{key: "active", value: JBool(true)},
			]),
			// nested
			JObject([
				{
					key: "items",
					value: JArray([
						JObject([{key: "id", value: JNumber(1)}]),
						JObject([{key: "id", value: JNumber(2)}]),
					]),
				},
			]),
			// all types in one
			JArray([
				JNull, JBool(true), JBool(false), JNumber(42), JString("s"),
				JArray([]), JObject([]),
			]),
		];

		for (i in 0...cases.length) {
			roundTrip(cases[i], 'case[$i]');
		}
	}

	function testRandomCases() {
		// Seeded linear congruential generator, so failures are reproducible.
		var rng = new SeededRng(42);
		for (i in 0...200) {
			var ast = randomValue(rng, 4);
			roundTrip(ast, 'random[$i]');
		}
	}

	static function randomValue(rng:SeededRng, depth:Int):JValue {
		// Leaves at zero depth, otherwise either leaf or composite.
		var kinds = depth <= 0 ? 4 : 6;
		return switch rng.nextInt(kinds) {
			case 0:
				JNull;
			case 1:
				JBool(rng.nextBool());
			case 2:
				JNumber(randomNumber(rng));
			case 3:
				JString(randomString(rng));
			case 4:
				var len = rng.nextInt(4);
				JArray([for (_ in 0...len) randomValue(rng, depth - 1)]);
			case 5:
				var len = rng.nextInt(4);
				JObject([for (i in 0...len) {
					key: 'k$i',
					value: randomValue(rng, depth - 1),
				}]);
			case _:
				JNull;
		}
	}

	static function randomNumber(rng:SeededRng):Float {
		return switch rng.nextInt(3) {
			case 0: rng.nextInt(100);
			case 1: -rng.nextInt(100);
			case 2:
				// Bounded float with two decimals, avoiding scientific notation
				// to keep the hand-written parser exercised on simple cases.
				Math.round(rng.nextFloat() * 10000) / 100;
			case _: 0;
		}
	}

	static function randomString(rng:SeededRng):String {
		var len = rng.nextInt(6);
		var buf = new StringBuf();
		for (_ in 0...len) {
			// ASCII a-z only, to keep generator simple. Escape handling is
			// covered separately in the curated cases.
			buf.addChar(0x61 + rng.nextInt(26));
		}
		return buf.toString();
	}
}

/**
	Tiny seeded linear congruential generator, used by the round-trip tests
	for reproducible random cases.
**/
private class SeededRng {
	var state:Int;

	public function new(seed:Int) {
		this.state = seed;
	}

	public function nextInt(max:Int):Int {
		state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
		return max == 0 ? 0 : state % max;
	}

	public function nextBool():Bool {
		return nextInt(2) == 0;
	}

	public function nextFloat():Float {
		state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
		return state / 2147483647.0;
	}
}
