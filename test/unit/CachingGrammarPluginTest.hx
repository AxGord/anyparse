package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.QueryNode;

/**
 * `CachingGrammarPlugin` memoizes `parseFile` / `parseFileTypeRefs` by source
 * content so N checks over one file parse it once. Verified by reference identity:
 * a cache hit returns the SAME tree instance, a different source a fresh one.
 */
class CachingGrammarPluginTest extends Test {

	public function testParseFileCachedByContent(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final src: String = 'class C {}';
		final first: QueryNode = cached.parseFile(src);
		final second: QueryNode = cached.parseFile(src);
		Assert.isTrue(first == second);
	}

	public function testDifferentContentNotShared(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final a: QueryNode = cached.parseFile('class A {}');
		final b: QueryNode = cached.parseFile('class B {}');
		Assert.isFalse(a == b);
	}

	public function testParseFileTypeRefsCached(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final src: String = 'class C { var x: Int; }';
		Assert.isTrue(cached.parseFileTypeRefs(src) == cached.parseFileTypeRefs(src));
	}

	public function testDelegatesUncachedMethods(): Void {
		final inner: HaxeQueryPlugin = new HaxeQueryPlugin();
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(inner);
		Assert.equals(inner.langName(), cached.langName());
		Assert.notNull(cached.refShape());
		Assert.notNull(cached.stringFoldSupport());
	}

}
