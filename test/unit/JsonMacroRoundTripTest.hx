package unit;

import utest.Assert;
import utest.Test;
// Importing JValue first so its @:build macro defines JValueFastParser
// before the compiler tries to resolve the next import.
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueFastParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonWriter;

/**
 * Macro parity for the round-trip invariant. Takes the same curated
 * cases and seeded-random corpus as `JsonRoundTripTest`, but the parse
 * step goes through the macro-generated `JValueFastParser` rather than
 * the hand-written `JsonParser`.
 */
class JsonMacroRoundTripTest extends Test {

	public function new() {
		super();
	}

	private function roundTrip(ast:JValue, ?label:String):Void {
		final written:String = JsonWriter.write(ast);
		var reparsed:JValue;
		try {
			reparsed = JValueFastParser.parse(written);
		} catch (e:haxe.Exception) {
			Assert.fail('parse failed for ${label != null ? label : "case"}: written=<$written>, err=${e.message}');
			return;
		}
		Assert.isTrue(JValueTools.equals(ast, reparsed),
			'round-trip failed for ${label != null ? label : Std.string(ast)}: written=<$written>, reparsed=$reparsed');
	}

	public function testCuratedCases() {
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

	public function testRandomCases() {
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
 * Tiny seeded linear congruential generator — kept private to this
 * file, duplicating `JsonRoundTripTest`'s helper to keep the macro
 * parity test self-contained. Shared helpers can be extracted once
 * more suites need them.
 */
private class SeededRng {

	private var state:Int;

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
