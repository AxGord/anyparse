package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;

using Lambda;

/**
 * Pins the batched `spanTypeInfo` bundle to the six individual `TypeInfoProvider`
 * accessors it replaces: `HaxeQueryPlugin.spanTypeInfo` computes all six span maps
 * in one parse, and `CachingGrammarPlugin` memoizes it and slices the accessors from
 * it. Both must stay byte-for-byte the pre-batching per-accessor results, so this
 * guards the (necessarily duplicated) combined visitor against drift.
 */
class SpanTypeInfoPinTest extends Test {

	private static final sources: Array<String> = [
		'class C {\n\tvar field: Ctx;\n\tfunction f(a: Foo, b: Bar): Array<Int> {\n\t\tvar x: Ctx = null;\n\t\tfinal y: Foo = a;\n\t\treturn null;\n\t}\n}',
		'class P {\n\tpublic var p(get, never): Int;\n\tpublic var q(default, null): String;\n\tvar plain: Int;\n\tfunction get_p(): Int return 1;\n}',
		'class K {\n\tfunction g(): Void {\n\t\tvar z = cast(w, Array<Int>);\n\t\tvar t: Int = (q : String);\n\t\tvar u: Map<String, Int> = null;\n\t}\n}',
		'typedef Ctx = { var f: Int; };\nclass M {\n\tstatic function mk(): Ctx return null;\n\tstatic function m(c: Ctx): Void {\n\t\tfinal d = c.f;\n\t}\n}',
		'enum E {\n\tA(x: Int);\n\tB(y: String);\n}\nabstract Ab(Int) from Int to Int {\n\tpublic function new(v: Int) this = v;\n}'
	];

	public function testBatchedEqualsIndividualOnHaxeQueryPlugin(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		for (src in sources)
			assertBundleMatches(
				plugin.spanTypeInfo(src), plugin.declaredTypes(src), plugin.returnTypes(src), plugin.propertyAccessors(src),
				plugin.propertyWriteAccessors(src), plugin.declaredTypeSources(src), plugin.castTargetSources(src), src
			);
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

}
