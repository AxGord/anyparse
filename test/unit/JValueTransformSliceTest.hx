package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;

// Import JValue first so its `@:build` macros define the sibling Fast
// parser, Fast writer and the deep transform before the imports below
// resolve.
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JStringLit;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JValueAst;
import anyparse.grammar.json.JValueTools;

/**
 * First-slice coverage for `Build.buildTransform` — the macro-generated
 * DEEP multi-type transform over the `JValue` family.
 *
 * The macro emits `JValueAst.transform(root, visit)` plus a
 * `JValueTransform` hook typedef (one optional `T -> T` per grammar
 * type). Unlike the earlier shallow `map`, the walk is whole-tree:
 * setting a single per-type hook rewrites every node of that type at any
 * depth, and an empty `{}` is a structural identity. Verifies:
 *  - DEEP per-type hooks (double every number leaf, upper-case every
 *    string leaf) mutate every matching node and round-trip
 *    byte-correctly through the existing writer.
 *  - The identity transform (`{}`) leaves the tree unchanged and
 *    byte-identical through the writer.
 *
 * Covers object, array, nested-mixed and primitive shapes.
 */
@:nullSafety(Strict)
class JValueTransformSliceTest extends Test {

	public function new(): Void {
		super();
	}

	// ---------------- per-type-hook contract ----------------

	public function testEmptyVisitIsIdentity(): Void {
		final ast: JValue = JArray([JNumber(1), JArray([JNumber(2)])]);
		final out: JValue = JValueAst.transform(ast, {});
		Assert.isTrue(JValueTools.equals(ast, out), 'empty visit changed the tree');
	}

	public function testHookRewritesEveryNodeOfType(): Void {
		// A `jValue` hook that replaces every value node with JNull
		// collapses the whole tree to the outermost rewrite (bottom-up:
		// children become JNull first, then the array itself).
		final ast: JValue = JArray([JNumber(1), JArray([JNumber(2)])]);
		final out: JValue = JValueAst.transform(ast, { jValue: _ -> JNull });
		Assert.isTrue(JValueTools.equals(JNull, out), 'jValue hook did not rewrite every node');
	}

	public function testTerminalHookFiresOnNestedLeaves(): Void {
		// A `jStringLit` hook rewrites the key terminal of every object
		// entry AND the string value — a Terminal-rule hook is a valid
		// rewrite site reached at any depth.
		final ast: JValue = JObject([{ key: 'a', value: JString('x') }]);
		final out: JValue = JValueAst.transform(ast, { jStringLit: (s: JStringLit) -> bang(s) });
		final expected: JValue = JObject([{ key: 'a!', value: JString('x!') }]);
		Assert.isTrue(JValueTools.equals(expected, out), 'jStringLit hook missed nested string terminals');
	}

	public function testEntryHookSeesTransformedChildren(): Void {
		// Bottom-up: the inner `value` is doubled by the `jValue` hook
		// BEFORE the `jEntry` hook runs, so an entry-level inspection sees
		// the already-transformed child.
		final ast: JValue = JObject([{ key: 'a', value: JNumber(5) }]);
		final out: JValue = JValueAst.transform(ast, {
			jValue: function(v: JValue): JValue {
				return switch v {
					case JNumber(n): JNumber((n: Float) * 2);
					case _: v;
				};
			},
		});
		final expected: JValue = JObject([{ key: 'a', value: JNumber(10) }]);
		Assert.isTrue(JValueTools.equals(expected, out), 'object-entry value not deep-transformed');
	}

	// ---------------- deep doubling ----------------

	public function testDeepDoublePrimitive(): Void {
		assertTransform(JNumber(21), JNumber(42), deepDouble, '42.0', 'double primitive');
		assertTransform(JNumber(-3), JNumber(-6), deepDouble, '-6.0', 'double negative');
		// Non-number primitives are untouched.
		assertTransform(JBool(true), JBool(true), deepDouble, 'true', 'double leaves bool');
		assertTransform(JNull, JNull, deepDouble, 'null', 'double leaves null');
	}

	public function testDeepDoubleArray(): Void {
		assertTransform(
			JArray([JNumber(1), JNumber(2), JNumber(3)]), JArray([JNumber(2), JNumber(4), JNumber(6)]), deepDouble, '[2.0, 4.0, 6.0]',
			'double array'
		);
	}

	public function testDeepDoubleObject(): Void {
		assertTransform(
			JObject([{ key: 'a', value: JNumber(10) }, { key: 'b', value: JNumber(20) }]),
			JObject([{ key: 'a', value: JNumber(20) }, { key: 'b', value: JNumber(40) }]), deepDouble, '{"a":20.0, "b":40.0}',
			'double object values'
		);
	}

	public function testDeepDoubleNested(): Void {
		final input: JValue = JObject([
			{
				key: 'items',
				value: JArray([
					JObject([{ key: 'id', value: JNumber(1) }]),
					JObject([{ key: 'id', value: JNumber(2) }]),
				])
			},
			{ key: 'count', value: JNumber(2) },
		]);
		final expected: JValue = JObject([
			{
				key: 'items',
				value: JArray([
					JObject([{ key: 'id', value: JNumber(2) }]),
					JObject([{ key: 'id', value: JNumber(4) }]),
				])
			},
			{ key: 'count', value: JNumber(4) },
		]);
		assertTransform(input, expected, deepDouble, '{"items":[{"id":2.0}, {"id":4.0}], "count":4.0}', 'double nested');
	}

	// ---------------- deep upper-casing ----------------

	public function testDeepUpper(): Void {
		final input: JValue = JObject([
			{ key: 'name', value: JString('john') },
			{ key: 'tags', value: JArray([JString('a'), JString('bc')]) },
			{ key: 'age', value: JNumber(30) },
		]);
		final expected: JValue = JObject([
			{ key: 'name', value: JString('JOHN') },
			{ key: 'tags', value: JArray([JString('A'), JString('BC')]) },
			{ key: 'age', value: JNumber(30) },
		]);
		assertTransform(input, expected, deepUpper, '{"name":"JOHN", "tags":["A", "BC"], "age":30.0}', 'upper nested');
	}

	// ---------------- identity / no-op ----------------

	public function testDeepIdentity(): Void {
		final cases: Array<JValue> = [
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
			JObject([{ key: 'x', value: JNumber(1) }, { key: 'y', value: JArray([JNumber(2)]) }]),
			JObject([
				{
					key: 'items',
					value: JArray([
						JObject([{ key: 'id', value: JNumber(1) }]),
						JObject([{ key: 'id', value: JNumber(2) }]),
					])
				},
			]),
		];
		for (i in 0...cases.length) {
			final ast: JValue = cases[i];
			final out: JValue = deepIdentity(ast);
			Assert.isTrue(JValueTools.equals(ast, out), 'identity changed the tree for case[$i]');
			// And the identity-transformed tree writes byte-identically.
			Assert.equals(JValueWriter.write(ast), JValueWriter.write(out), 'identity byte-regressed for case[$i]');
		}
	}

	/**
	 * Apply `f` deeply to `input`, assert the result equals `expected`
	 * both structurally and through a writer-then-reparse round-trip, and
	 * that the writer emits `expectedText`.
	 */
	private function assertTransform(input: JValue, expected: JValue, f: JValue -> JValue, expectedText: String, tag: String): Void {
		final out: JValue = f(input);
		Assert.isTrue(JValueTools.equals(expected, out), 'structural mismatch for $tag: got=$out');

		final written: String = JValueWriter.write(out);
		Assert.equals(expectedText, written, 'writer text mismatch for $tag');

		var reparsed: JValue;
		try {
			reparsed = JValueParser.parse(written);
		} catch (exception: Exception) {
			Assert.fail('reparse failed for $tag: written=<$written>, err=${exception.message}');
			return;
		}
		Assert.isTrue(JValueTools.equals(expected, reparsed), 'round-trip mismatch for $tag: reparsed=$reparsed');
	}

	// ---------------- deep per-type hooks ----------------

	/** Deep transform: double every `JNumber` leaf, in one walk. */
	private static function deepDouble(node: JValue): JValue {
		return JValueAst.transform(node, {
			jValue: function(v: JValue): JValue {
				return switch v {
					case JNumber(n): JNumber((n: Float) * 2);
					case _: v;
				};
			},
		});
	}

	/** Deep transform: upper-case every `JString` leaf (object keys left intact). */
	private static function deepUpper(node: JValue): JValue {
		return JValueAst.transform(node, {
			jValue: function(v: JValue): JValue {
				return switch v {
					case JString(s): JString((s: String).toUpperCase());
					case _: v;
				};
			},
		});
	}

	/** Identity transform: empty `visit`, deep no-op. */
	private static function deepIdentity(node: JValue): JValue {
		return JValueAst.transform(node, {});
	}

	/** Append `!` to a JSON string terminal (transparent over String). */
	private static function bang(s: JStringLit): JStringLit {
		return (s: String) + '!';
	}

}
