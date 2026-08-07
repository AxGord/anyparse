package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Refs.RefHit;
import anyparse.query.RefsCache;

/**
 * `RefsCache` memoizes `Refs.find` per tree: `CachingGrammarPlugin.refShape`
 * attaches a run-scoped cache that primes ONE `Refs.findMulti` walk over
 * every name in the tree, then serves each subsequent `find` as a map slice.
 *
 * Coverage:
 *  - Equivalence: for every distinct name in a fixture exercising shadowed
 *    locals, a self-scoped `for` iterator, a catch clause, a lambda param,
 *    reads/writes, an opaque `macro { … }` subtree, a forward-declared
 *    same-scope binding, class members, and an unresolved name — the
 *    cache-path result must match the bare (uncached) `Refs.find` result
 *    element-wise.
 *  - Copy semantics: mutating a returned array must not poison the memo.
 *  - Wiring: `CachingGrammarPlugin.refShape()` attaches a non-null cache,
 *    the SAME instance across calls; a bare `HaxeQueryPlugin` leaves it
 *    unset.
 */
class RefsCacheTest extends Test {

	// Exercises: shadowed locals across nested blocks, a `for` iterator
	// (self-scope), a catch clause, a lambda param, writes (`x = 1`,
	// `x++`), a `macro { … }` opaque subtree, a forward-declared same-scope
	// binding, class members + a this-less member read, and an unresolved
	// (cross-file) name via `externalCall()`.
	private static final FIXTURE: String = '
		class X {
			var shared: Int = 0;

			static function outer(): Void {
				var shared: Int = 1;
				{
					var shared: Int = 2;
					shared = 3;
					shared++;
				}
				for (i in 0...10) {
					var y = i;
				}
				try {
					risky();
				} catch (e: String) {
					use(e);
				}
				var fn = (p) -> p + 1;
				var e = macro { emit(shared); };
				forward();
				externalCall();
			}

			static function forward(): Void {}

			static function risky(): Void {}

			static function use(v: String): Void {}

			static function emit(v: Int): Void {}
		}
	';

	public function testCachePathMatchesBareFindForEveryName(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(FIXTURE);
		final bareShape: RefShape = plugin.refShape();

		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(plugin);
		final cachedShape: RefShape = cached.refShape();

		final names: Array<String> = [];
		RefsCache.collectNames(tree, names);
		final seen: Array<String> = [];
		for (n in names) if (!seen.contains(n)) seen.push(n);

		Assert.isTrue(seen.length > 0, 'fixture must contain at least one name');

		for (name in seen) {
			final expected: Array<RefHit> = Refs.find(name, tree, bareShape);
			final actual: Array<RefHit> = Refs.find(name, tree, cachedShape);
			Assert.equals(
				expected.length, actual.length, 'name "$name": hit count mismatch — bare ${expected.length}, cached ${actual.length}'
			);
			for (i in 0...expected.length) {
				final e: RefHit = expected[i];
				final a: RefHit = actual[i];
				Assert.equals(e.kind, a.kind, 'name "$name" hit $i: kind mismatch');
				Assert.equals(e.name, a.name, 'name "$name" hit $i: name mismatch');
				Assert.equals(e.span.from, a.span.from, 'name "$name" hit $i: span.from mismatch');
				Assert.equals(e.span.to, a.span.to, 'name "$name" hit $i: span.to mismatch');
				Assert.equals(e.bindingSpan == null, a.bindingSpan == null, 'name "$name" hit $i: bindingSpan nullity mismatch');
				if (e.bindingSpan != null && a.bindingSpan != null)
					Assert.equals(e.bindingSpan.from, a.bindingSpan.from, 'name "$name" hit $i: bindingSpan.from mismatch');
			}
		}
	}

	public function testMutatingReturnedArrayDoesNotPoisonMemo(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(FIXTURE);
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(plugin);
		final shape: RefShape = cached.refShape();

		final first: Array<RefHit> = Refs.find('shared', tree, shape);
		final originalLength: Int = first.length;
		Assert.isTrue(originalLength > 0, 'fixture must reference "shared" at least once');
		first.pop();

		final second: Array<RefHit> = Refs.find('shared', tree, shape);
		Assert.equals(originalLength, second.length, 'mutating a returned array must not shrink the memoized result on the next query');
	}

	public function testRefShapeAttachesNonNullSharedCache(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(plugin);
		final first: RefShape = cached.refShape();
		final second: RefShape = cached.refShape();
		Assert.notNull(first.refsCache, 'CachingGrammarPlugin.refShape() must attach a RefsCache');
		Assert.isTrue(first.refsCache == second.refsCache, 'two refShape() calls must carry the SAME RefsCache instance');
	}

	public function testBarePluginLeavesRefsCacheUnset(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		Assert.isNull(shape.refsCache, 'a bare HaxeQueryPlugin must not attach a RefsCache');
	}

}
