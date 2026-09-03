package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Pins the six span-indexed maps the generated span-info walk produces.
 *
 * The six `TypeInfoProvider` accessors are now SLICES of the one bundle, so
 * comparing them against it can no longer catch drift - there is only one
 * implementation left to drift from. `testBundleValuesArePinned` is what makes
 * this suite a net: it asserts the actual contents, captured from the reflective
 * walk the generated one replaced and verified equal to it on all five fixtures.
 * The accessor tests keep their own job - that the plugin and the caching
 * decorator both hand back the SAME bundle instead of recomputing it.
 */
class SpanTypeInfoPinTest extends Test {

	private static final sources: Array<String> = [
		'class C {\n\tvar field: Ctx;\n\tfunction f(a: Foo, b: Bar): Array<Int> {\n\t\tvar x: Ctx = null;\n\t\tfinal y: Foo = a;\n'
			+ '\t\treturn null;\n\t}\n}',
		'class P {\n\tpublic var p(get, never): Int;\n\tpublic var q(default, null): String;\n\tvar plain: Int;\n'
			+ '\tfunction get_p(): Int return 1;\n}',
		'class K {\n\tfunction g(): Void {\n\t\tvar z = cast(w, Array<Int>);\n\t\tvar t: Int = (q : String);\n'
			+ '\t\tvar u: Map<String, Int> = null;\n\t}\n}',
		'typedef Ctx = { var f: Int; };\nclass M {\n\tstatic function mk(): Ctx return null;\n\tstatic function m(c: Ctx): Void {\n'
			+ '\t\tfinal d = c.f;\n\t}\n}',
		'enum E {\n\tA(x: Int);\n\tB(y: String);\n}\nabstract Ab(Int) from Int to Int {\n\tpublic function new(v: Int) this = v;\n}'
	];

	public function testAccessorsSliceTheBundle(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		for (src in sources) {
			final bundle: SpanTypeInfo = plugin.spanTypeInfo(src);
			assertBundleMatches(
				bundle, plugin.declaredTypes(src), plugin.returnTypes(src), plugin.propertyAccessors(src),
				plugin.propertyWriteAccessors(src), plugin.declaredTypeSources(src), plugin.castTargetSources(src), src
			);
		}
	}

	public function testCachingPluginSlicesAndReuses(): Void {
		for (src in sources) {
			final caching: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
			final bundle: SpanTypeInfo = caching.spanTypeInfo(src);
			assertBundleMatches(
				bundle, caching.declaredTypes(src), caching.returnTypes(src), caching.propertyAccessors(src),
				caching.propertyWriteAccessors(src), caching.declaredTypeSources(src), caching.castTargetSources(src), src
			);
			Assert.isTrue(bundle == caching.spanTypeInfo(src), 'the caching plugin returns the memoized bundle instance');
			Assert.isTrue(bundle.declaredTypes == caching.declaredTypes(src), 'the accessor returns the bundle slice, not a fresh map');
		}
	}

	public function testCachingMatchesRawPlugin(): Void {
		final raw: HaxeQueryPlugin = new HaxeQueryPlugin();
		for (src in sources) {
			final caching: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
			final b: SpanTypeInfo = caching.spanTypeInfo(src);
			assertBundleMatches(
				b, raw.declaredTypes(src), raw.returnTypes(src), raw.propertyAccessors(src), raw.propertyWriteAccessors(src),
				raw.declaredTypeSources(src), raw.castTargetSources(src), src
			);
		}
	}

	/**
	 * The bundle CONTENTS, fixture by fixture. Captured from the reflective walk the
	 * generated one replaced, after confirming the two agreed on every one of these
	 * five sources - so a change to the emitted walk that alters what a check sees
	 * fails here instead of silently moving findings across the corpus.
	 */
	public function testBundleValuesArePinned(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final expected: Array<Array<String>> = [
			[
				'[11=>Ctx, 39=>Foo, 47=>Bar, 56=>Int, 71=>Ctx, 92=>Foo]',
				'[28=>Array]',
				'[]',
				'[]',
				'[11=>Ctx, 39=>Foo, 47=>Bar, 56=>Int, 71=>Ctx, 92=>Foo]',
				'[]'
			],
			[
				'[18=>Int, 50=>String, 81=>Int]',
				'[98=>Int]',
				'[18=>true, 50=>false]',
				'[18=>false, 50=>false]',
				'[18=>Int, 50=>String, 81=>Int]',
				'[]'
			],
			[
				'[42=>Array, 50=>Int, 65=>Int, 78=>String, 94=>Map, 101=>Int]',
				'[11=>Void]',
				'[]',
				'[]',
				'[42=>Array<Int>, 50=>Int, 65=>Int, 78=>String, 94=>Map<String, Int>, 101=>Int]',
				'[42=>Array<Int>, 78=>String]'
			],
			[
				'[20=>Int, 100=>Ctx]',
				'[49=>Ctx, 89=>Void]',
				'[]',
				'[]',
				'[0=>{ var f: Int; }, 20=>Int, 100=>Ctx]',
				'[]'
			],
			[
				'[12=>Int, 24=>String, 94=>Int]',
				'[]',
				'[]',
				'[]',
				'[12=>Int, 24=>String, 94=>Int]',
				'[]'
			]
		];
		for (i in 0...sources.length) {
			final b: SpanTypeInfo = plugin.spanTypeInfo(sources[i]);
			final e: Array<String> = expected[i];
			Assert.equals(e[0], render(b.declaredTypes), 'declaredTypes for fixture $i');
			Assert.equals(e[1], render(b.returnTypes), 'returnTypes for fixture $i');
			Assert.equals(e[2], render(b.propertyAccessors), 'propertyAccessors for fixture $i');
			Assert.equals(e[3], render(b.propertyWriteAccessors), 'propertyWriteAccessors for fixture $i');
			Assert.equals(e[4], render(b.declaredTypeSources), 'declaredTypeSources for fixture $i');
			Assert.equals(e[5], render(b.castTargetSources), 'castTargetSources for fixture $i');
		}
	}

	private static function assertBundleMatches(
		bundle: SpanTypeInfo, declaredTypes: Map<Int, String>, returnTypes: Map<Int, String>, propertyAccessors: Map<Int, Bool>,
		propertyWriteAccessors: Map<Int, Bool>, declaredTypeSources: Map<Int, String>, castTargetSources: Map<Int, String>, src: String
	): Void {
		eqStr(bundle.declaredTypes, declaredTypes, 'declaredTypes', src);
		eqStr(bundle.returnTypes, returnTypes, 'returnTypes', src);
		eqBool(bundle.propertyAccessors, propertyAccessors, 'propertyAccessors', src);
		eqBool(bundle.propertyWriteAccessors, propertyWriteAccessors, 'propertyWriteAccessors', src);
		eqStr(bundle.declaredTypeSources, declaredTypeSources, 'declaredTypeSources', src);
		eqStr(bundle.castTargetSources, castTargetSources, 'castTargetSources', src);
	}

	private static function eqStr(a: Map<Int, String>, b: Map<Int, String>, label: String, src: String): Void {
		Assert.equals(a.count(), b.count(), '$label size for <$src>');
		for (k => value in a) Assert.equals(b[k], value, '$label key $k for <$src>');
		for (k in b.keys()) Assert.isTrue(a.exists(k), '$label missing key $k for <$src>');
	}

	private static function eqBool(a: Map<Int, Bool>, b: Map<Int, Bool>, label: String, src: String): Void {
		Assert.equals(a.count(), b.count(), '$label size for <$src>');
		for (k => value in a) Assert.equals(b[k], value, '$label key $k for <$src>');
		for (k in b.keys()) Assert.isTrue(a.exists(k), '$label missing key $k for <$src>');
	}

	/** A span map as a key-ordered `[from=>value, ...]` string, so a mismatch reads as a diff rather than a count. */
	private static function render<V>(m: Map<Int, V>): String {
		final keys: Array<Int> = [for (k in m.keys()) k];
		keys.sort((a, b) -> a - b);
		return '[${keys.map(k -> '$k=>${m[k]}').join(', ')}]';
	}

}
