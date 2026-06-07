package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
// Import JValue first so its `@:build` macros define the sibling Fast
// parser, Fast writer and the transform `map` before the imports below
// resolve.
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JValueTransform;
import anyparse.grammar.json.JValueTools;

/**
 * First-slice coverage for `Build.buildTransform` — the macro-generated
 * shallow `map` over the `JValue` family.
 *
 * Verifies two things end-to-end:
 *  - DEEP transforms composed by calling `JValueTransform.map` inside a
 *    recursive `f` mutate every node of the tree (numbers doubled,
 *    strings upper-cased) and the result both compares structurally and
 *    round-trips byte-correctly through the existing writer.
 *  - The identity map (`f = x -> x`, applied deeply) leaves the tree
 *    unchanged and byte-identical through the writer.
 *
 * Covers object, array, nested-mixed and primitive shapes.
 */
@:nullSafety(Strict)
class JValueTransformSliceTest extends Test {

	public function new():Void {
		super();
	}

	// ---------------- deep recursive transformers ----------------

	/**
	 * Deep map: double every number leaf. Recurses into children first
	 * via `JValueTransform.map`, then applies the leaf change at this
	 * node — the canonical `ExprTools.map` composition.
	 */
	private static function deepDouble(node:JValue):JValue {
		final mapped:JValue = JValueTransform.map(node, deepDouble);
		return switch mapped {
			case JNumber(v): JNumber((v : Float) * 2);
			case _: mapped;
		};
	}

	/** Deep map: upper-case every string leaf (object keys are left intact). */
	private static function deepUpper(node:JValue):JValue {
		final mapped:JValue = JValueTransform.map(node, deepUpper);
		return switch mapped {
			case JString(v): JString((v : String).toUpperCase());
			case _: mapped;
		};
	}

	/** Identity leaf function, composed deeply. */
	private static function deepIdentity(node:JValue):JValue {
		return JValueTransform.map(node, deepIdentity);
	}

	// ---------------- shallow-contract assertions ----------------

	public function testShallowDoesNotRecurse():Void {
		// A shallow map with identity `f` on a nested array leaves the
		// tree equal; the point is that `map` itself does not descend —
		// `f` is the identity so the single level it touches is a no-op.
		final ast:JValue = JArray([JNumber(1), JArray([JNumber(2)])]);
		final out:JValue = JValueTransform.map(ast, x -> x);
		Assert.isTrue(JValueTools.equals(ast, out), 'shallow identity changed the tree');
	}

	public function testShallowAppliesToImmediateChildrenOnly():Void {
		// Replace immediate children with JNull. The nested JNumber(2)
		// inside the inner array must survive untouched, because `map` is
		// shallow — it only sees the two top-level array elements.
		final ast:JValue = JArray([JNumber(1), JArray([JNumber(2)])]);
		final out:JValue = JValueTransform.map(ast, _ -> JNull);
		final expected:JValue = JArray([JNull, JNull]);
		Assert.isTrue(JValueTools.equals(expected, out), 'shallow map touched a non-immediate child');
	}

	public function testShallowObjectEntryValueIsImmediate():Void {
		// An object entry's `value` is reached as an immediate family
		// child even though it sits one struct level deep; its key is a
		// non-family leaf and must be copied verbatim.
		final ast:JValue = JObject([{key: 'a', value: JNumber(5)}]);
		final out:JValue = JValueTransform.map(ast, _ -> JBool(true));
		final expected:JValue = JObject([{key: 'a', value: JBool(true)}]);
		Assert.isTrue(JValueTools.equals(expected, out), 'object-entry value not mapped, or key not preserved');
	}

	// ---------------- deep doubling ----------------

	public function testDeepDoublePrimitive():Void {
		assertTransform(JNumber(21), JNumber(42), deepDouble, '42.0', 'double primitive');
		assertTransform(JNumber(-3), JNumber(-6), deepDouble, '-6.0', 'double negative');
		// Non-number primitives are untouched.
		assertTransform(JBool(true), JBool(true), deepDouble, 'true', 'double leaves bool');
		assertTransform(JNull, JNull, deepDouble, 'null', 'double leaves null');
	}

	public function testDeepDoubleArray():Void {
		assertTransform(
			JArray([JNumber(1), JNumber(2), JNumber(3)]),
			JArray([JNumber(2), JNumber(4), JNumber(6)]),
			deepDouble, '[2.0, 4.0, 6.0]', 'double array'
		);
	}

	public function testDeepDoubleObject():Void {
		assertTransform(
			JObject([{key: 'a', value: JNumber(10)}, {key: 'b', value: JNumber(20)}]),
			JObject([{key: 'a', value: JNumber(20)}, {key: 'b', value: JNumber(40)}]),
			deepDouble, '{"a":20.0, "b":40.0}', 'double object values'
		);
	}

	public function testDeepDoubleNested():Void {
		final input:JValue = JObject([
			{key: 'items', value: JArray([
				JObject([{key: 'id', value: JNumber(1)}]),
				JObject([{key: 'id', value: JNumber(2)}]),
			])},
			{key: 'count', value: JNumber(2)},
		]);
		final expected:JValue = JObject([
			{key: 'items', value: JArray([
				JObject([{key: 'id', value: JNumber(2)}]),
				JObject([{key: 'id', value: JNumber(4)}]),
			])},
			{key: 'count', value: JNumber(4)},
		]);
		assertTransform(input, expected, deepDouble, '{"items":[{"id":2.0}, {"id":4.0}], "count":4.0}', 'double nested');
	}

	// ---------------- deep upper-casing ----------------

	public function testDeepUpper():Void {
		final input:JValue = JObject([
			{key: 'name', value: JString('john')},
			{key: 'tags', value: JArray([JString('a'), JString('bc')])},
			{key: 'age', value: JNumber(30)},
		]);
		final expected:JValue = JObject([
			{key: 'name', value: JString('JOHN')},
			{key: 'tags', value: JArray([JString('A'), JString('BC')])},
			{key: 'age', value: JNumber(30)},
		]);
		assertTransform(input, expected, deepUpper, '{"name":"JOHN", "tags":["A", "BC"], "age":30.0}', 'upper nested');
	}

	// ---------------- identity / no-op ----------------

	public function testDeepIdentity():Void {
		final cases:Array<JValue> = [
			JNull,
			JBool(true),
			JBool(false),
			JNumber(42),
			JNumber(-3.5),
			JString('hello'),
			JString('has "quotes"'),
			JArray([]),
			JObject([]),
			JArray([JNull, JBool(false), JNumber(1), JString('x')]),
			JObject([{key: 'x', value: JNumber(1)}, {key: 'y', value: JArray([JNumber(2)])}]),
			JObject([
				{key: 'items', value: JArray([
					JObject([{key: 'id', value: JNumber(1)}]),
					JObject([{key: 'id', value: JNumber(2)}]),
				])},
			]),
		];
		for (i in 0...cases.length) {
			final ast:JValue = cases[i];
			final out:JValue = deepIdentity(ast);
			Assert.isTrue(JValueTools.equals(ast, out), 'identity changed the tree for case[$i]');
			// And the identity-mapped tree writes byte-identically.
			Assert.equals(JValueWriter.write(ast), JValueWriter.write(out), 'identity byte-regressed for case[$i]');
		}
	}

	/**
	 * Apply `f` deeply to `input`, assert the result equals `expected`
	 * both structurally and through a writer-then-reparse round-trip, and
	 * that the writer emits `expectedText`.
	 */
	private function assertTransform(input:JValue, expected:JValue, f:JValue -> JValue, expectedText:String, tag:String):Void {
		final out:JValue = f(input);
		Assert.isTrue(JValueTools.equals(expected, out), 'structural mismatch for $tag: got=$out');

		final written:String = JValueWriter.write(out);
		Assert.equals(expectedText, written, 'writer text mismatch for $tag');

		var reparsed:JValue;
		try {
			reparsed = JValueParser.parse(written);
		} catch (exception:Exception) {
			Assert.fail('reparse failed for $tag: written=<$written>, err=${exception.message}');
			return;
		}
		Assert.isTrue(JValueTools.equals(expected, reparsed), 'round-trip mismatch for $tag: reparsed=$reparsed');
	}
}
