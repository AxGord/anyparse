package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.GrammarPlugin.LayoutMetrics;

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

	public function testProjectBranchAwareCached(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if A\n\t\ta();\n\t\t#else\n\t\tb();\n\t\t#end\n\t}\n}';
		final tree: QueryNode = cached.parseFile(src);
		Assert.isTrue(cached.projectBranchAware(tree, src) == cached.projectBranchAware(tree, src));
	}

	public function testLayoutMetricsCachedByConfig(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final json: String = '{"wrapping": {"maxLineLength": 100}}';
		Assert.isTrue(cached.layoutMetrics(json) == cached.layoutMetrics(json));
	}

	public function testLayoutMetricsDifferentConfigNotShared(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final wide: Null<LayoutMetrics> = cached.layoutMetrics('{"wrapping": {"maxLineLength": 100}}');
		final narrow: Null<LayoutMetrics> = cached.layoutMetrics('{"wrapping": {"maxLineLength": 80}}');
		// The OBSERVABLE difference, not reference inequality: two anon structs are
		// never the same instance, so `wide != narrow` holds with no cache at all.
		Assert.equals(100, wide == null ? -1 : wide.lineWidth);
		Assert.equals(80, narrow == null ? -1 : narrow.lineWidth);
	}

	/**
	 * A BLANK config text — what a 0-byte `hxformat.json` reads as — states no
	 * settings, so it keys as NO config rather than as a config of its own. Reference
	 * identity is the assertion because sharing the ENTRY is the claim: keeping the two
	 * apart is what let `layoutMetrics` answer `''` while `writeRoundTrip` raised on it,
	 * and a width-aware rule then reported findings it could never apply.
	 */
	public function testLayoutMetricsBlankConfigKeysAsNoConfig(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.isTrue(cached.layoutMetrics('') == cached.layoutMetrics(null));
		Assert.isTrue(cached.layoutMetrics('  \n\t') == cached.layoutMetrics(null));
	}

	/** The WRITE half of that agreement: a blank config resolves to the defaults instead of reaching the JSON parser. */
	public function testWriteRoundTripAcceptsBlankConfig(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.equals(cached.writeRoundTrip('class C {}\n', null), cached.writeRoundTrip('class C {}\n', ''));
	}

	public function testDelegatesUncachedMethods(): Void {
		final inner: HaxeQueryPlugin = new HaxeQueryPlugin();
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(inner);
		Assert.equals(inner.langName(), cached.langName());
		Assert.notNull(cached.refShape());
		Assert.notNull(cached.stringFoldSupport());
	}

}
