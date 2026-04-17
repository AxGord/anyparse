package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
// Importing JValue first so its `@:build` macros define the sibling
// Fast parser and Fast writer before the imports below resolve.
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JValueTools;

/**
 * Round-trip invariant for JSON through the macro pipeline:
 * `parse(write(ast)) == ast`. Covers a curated set of shapes plus a
 * seeded-random corpus so regressions in either direction surface
 * with a reproducible seed.
 */
@:nullSafety(Strict)
class JsonRoundTripTest extends Test {

	public function new():Void {
		super();
	}

	private function roundTrip(ast:JValue, ?label:String):Void {
		final written:String = JValueWriter.write(ast);
		final tag:String = label ?? 'case';
		var reparsed:JValue;
		try {
			reparsed = JValueParser.parse(written);
		} catch (exception:Exception) {
			Assert.fail('parse failed for $tag: written=<$written>, err=${exception.message}');
			return;
		}
		Assert.isTrue(JValueTools.equals(ast, reparsed),
			'round-trip failed for $tag: written=<$written>, reparsed=$reparsed');
	}

	public function testCuratedCases():Void {
		final cases:Array<JValue> = [
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
			JString(''),
			JString('hello'),
			JString('with\nnewline'),
			JString('has "quotes"'),
			JString('back\\slash'),
			JString('tab\there'),
			JArray([]),
			JArray([JNull]),
			JArray([JBool(true), JBool(false)]),
			JArray([JNumber(1), JNumber(2), JNumber(3)]),
			JArray([JString('a'), JString('b'), JString('c')]),
			JObject([]),
			JObject([{key: 'x', value: JNumber(1)}]),
			JObject([
				{key: 'name', value: JString('John')},
				{key: 'age', value: JNumber(30)},
				{key: 'active', value: JBool(true)},
			]),
			JObject([
				{
					key: 'items',
					value: JArray([
						JObject([{key: 'id', value: JNumber(1)}]),
						JObject([{key: 'id', value: JNumber(2)}]),
					]),
				},
			]),
			JArray([
				JNull, JBool(true), JBool(false), JNumber(42), JString('s'),
				JArray([]), JObject([]),
			]),
		];
		for (i in 0...cases.length) roundTrip(cases[i], 'case[$i]');
	}

	public function testRandomCases():Void {
		final rng:SeededRng = new SeededRng(42);
		for (i in 0...200) {
			final ast:JValue = randomValue(rng, 4);
			roundTrip(ast, 'random[$i]');
		}
	}

	private static function randomValue(rng:SeededRng, depth:Int):JValue {
		final kinds:Int = depth <= 0 ? 4 : 6;
		return switch rng.nextInt(kinds) {
			case 0: JNull;
			case 1: JBool(rng.nextBool());
			case 2: JNumber(randomNumber(rng));
			case 3: JString(randomString(rng));
			case 4:
				final len:Int = rng.nextInt(4);
				JArray([for (_ in 0...len) randomValue(rng, depth - 1)]);
			case 5:
				final len:Int = rng.nextInt(4);
				JObject([for (i in 0...len) {key: 'k$i', value: randomValue(rng, depth - 1)}]);
			case _: JNull;
		};
	}

	private static function randomNumber(rng:SeededRng):Float {
		return switch rng.nextInt(3) {
			case 0: rng.nextInt(100);
			case 1: -rng.nextInt(100);
			case 2: Math.round(rng.nextFloat() * 10000) / 100;
			case _: 0;
		};
	}

	private static function randomString(rng:SeededRng):String {
		final len:Int = rng.nextInt(6);
		final buf:StringBuf = new StringBuf();
		for (_ in 0...len) buf.addChar(0x61 + rng.nextInt(26));
		return buf.toString();
	}
}

/**
 * Tiny seeded linear congruential generator — private to this file so
 * random round-trip failures stay reproducible across runs without a
 * shared helper dependency.
 */
private final class SeededRng {

	private var _state:Int;

	public function new(seed:Int):Void {
		_state = seed;
	}

	public inline function nextInt(max:Int):Int {
		_state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
		return max == 0 ? 0 : _state % max;
	}

	public inline function nextBool():Bool {
		return nextInt(2) == 0;
	}

	public inline function nextFloat():Float {
		_state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
		return _state / 2147483647.0;
	}
}
