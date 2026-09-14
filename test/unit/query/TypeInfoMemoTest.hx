package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.TypeInfoMemo;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import utest.Assert;
import utest.Test;

/**
 * `TypeInfoMemo` — each table is computed on the first call and the same map is answered after it,
 * a null provider answers the empty map, and `TypeResolver.memoizedDeclaredTypeSources` is the same
 * thunk resolved from a plugin. Green at base by construction: the thunks restate the closures the
 * checks held inline.
 */
@:nullSafety(Strict)
class TypeInfoMemoTest extends Test {

	private static inline final SOURCE: String = 'class C {\n\tfunction f(): Void {\n\t\tfinal s: String = cast(1, String);\n\t}\n}\n';

	private final _plugin: HaxeQueryPlugin = new HaxeQueryPlugin();

	public function testCastTargetsAreComputedOnceAndAnswerTheSameMap(): Void {
		final provider: TypeInfoProvider = _plugin;
		final casts: () -> Map<Int, String> = TypeInfoMemo.castTargetSources(provider, SOURCE);
		final first: Map<Int, String> = casts();
		Assert.equals(first, casts());
		Assert.isTrue([for (k in first.keys()) k].length > 0);
		Assert.isTrue([for (v in first) v].contains('String'));
	}

	public function testDeclaredTypeSourcesMatchTheResolverEntryPoint(): Void {
		final provider: TypeInfoProvider = _plugin;
		final direct: Map<Int, String> = TypeInfoMemo.declaredTypeSources(provider, SOURCE)();
		final viaResolver: Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(_plugin, SOURCE)();
		Assert.same([for (k => v in direct) '$k=$v'], [for (k => v in viaResolver) '$k=$v']);
		Assert.isTrue([for (v in direct) v].contains('String'));
	}

	public function testANullProviderAnswersTheEmptyMap(): Void {
		Assert.equals(0, [for (k in TypeInfoMemo.castTargetSources(null, SOURCE)().keys()) k].length);
		Assert.equals(0, [for (k in TypeInfoMemo.declaredTypeSources(null, SOURCE)().keys()) k].length);
	}

}
