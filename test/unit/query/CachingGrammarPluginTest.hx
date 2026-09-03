package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin.LayoutMetrics;
import anyparse.query.QueryNode;
import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;
import anyparse.runtime.Span;
import haxe.Exception;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

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

	/**
	 * The counter proof for the shared parsed root: the four projections of ONE source cost
	 * ONE parse, where each of them used to parse that source itself. A second distinct
	 * source must add exactly one more, so a counter frozen at 1 fails here instead of
	 * reading as a pass.
	 */
	public function testOneParseServesEveryProjection(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final first: String = 'class OneParseProbeA<T> {\n\tvar x: Int;\n\tfunction f(): Void {}\n}';
		final second: String = 'class OneParseProbeB {\n\tvar y: String;\n}';
		final before: Int = cached.rootParses;
		projectEveryWay(cached, first);
		Assert.equals(1, cached.rootParses - before, 'four projections of one source cost ONE parse');
		projectEveryWay(cached, second);
		Assert.equals(2, cached.rootParses - before, 'a second distinct source costs exactly one more');
	}

	/**
	 * The seam is output-NEUTRAL: every projection taken through the shared root returns
	 * what the UNWRAPPED plugin returns for the same source. The fixture carries an import,
	 * a type parameter, a typed field and a typed cast so that none of the comparisons is
	 * vacuously empty - the non-emptiness is asserted, not assumed.
	 */
	public function testProjectionsUnchangedByTheSharedRoot(): Void {
		final plain: HaxeQueryPlugin = new HaxeQueryPlugin();
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final src: String = 'package probe;\n\nimport haxe.io.Bytes;\n\nclass SharedRootProbe<T> {\n\n'
			+ '\tpublic var raw: Bytes;\n\n\tpublic function new() {\n\t\traw = Bytes.alloc(1);\n\t}\n\n'
			+ '\tpublic function pick(v: T): Int {\n\t\treturn cast(v, Int);\n\t}\n\n}\n';

		final plainTree: String = shapeOf(plain.parseFile(src));
		Assert.isTrue(plainTree.length > 100, 'the fixture projects a real tree - the shape comparisons are not vacuous');
		Assert.equals(plainTree, shapeOf(cached.parseFile(src)), 'parseFile');
		Assert.equals(shapeOf(plain.parseFileTypeRefs(src)), shapeOf(cached.parseFileTypeRefs(src)), 'parseFileTypeRefs');

		final plainInfo: SpanTypeInfo = plain.spanTypeInfo(src);
		final sharedInfo: SpanTypeInfo = cached.spanTypeInfo(src);
		Assert.notEquals('', mapDigest(plainInfo.declaredTypes), 'the fixture fills declaredTypes');
		Assert.notEquals('', mapDigest(plainInfo.castTargetSources), 'the fixture fills castTargetSources');
		Assert.equals(mapDigest(plainInfo.declaredTypes), mapDigest(sharedInfo.declaredTypes), 'declaredTypes');
		Assert.equals(mapDigest(plainInfo.returnTypes), mapDigest(sharedInfo.returnTypes), 'returnTypes');
		Assert.equals(mapDigest(plainInfo.propertyAccessors), mapDigest(sharedInfo.propertyAccessors), 'propertyAccessors');
		Assert.equals(mapDigest(plainInfo.propertyWriteAccessors), mapDigest(sharedInfo.propertyWriteAccessors), 'propertyWriteAccessors');
		Assert.equals(mapDigest(plainInfo.declaredTypeSources), mapDigest(sharedInfo.declaredTypeSources), 'declaredTypeSources');
		Assert.equals(mapDigest(plainInfo.castTargetSources), mapDigest(sharedInfo.castTargetSources), 'castTargetSources');

		Assert.notEquals('', mapDigest(plain.importMap(src)), 'the fixture fills importMap');
		Assert.equals(mapDigest(plain.importMap(src)), mapDigest(cached.importMap(src)), 'importMap');
	}

	/**
	 * A source that does not parse keeps behaving exactly as before: `parseFile` throws and
	 * leaves nothing in the tree cache, so a second call throws again; the other projections
	 * answer empty. The NULL root is memoised like any other, so those four calls cost one
	 * parse attempt rather than one each.
	 */
	public function testSkipParseSourceStillThrowsAndIsNotCached(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final src: String = 'class SkipParseProbe { function (';
		final before: Int = cached.rootParses;
		Assert.raises(cached.parseFile.bind(src), Exception);
		Assert.raises(cached.parseFile.bind(src), Exception);
		Assert.isFalse(cached.spanTypeInfo(src).declaredTypes.keys().hasNext(), 'a failed parse yields the empty bundle');
		Assert.isFalse(cached.importMap(src).keys().hasNext(), 'a failed parse yields the empty import map');
		Assert.equals(1, cached.rootParses - before, 'the failed parse is memoised too - one attempt, not four');
	}

	/**
	 * The shared root survives being projected repeatedly and in ANY order — a walk must
	 * neither consume nor mutate it. The reverse-order wrapper works off a root the walker
	 * memo was forced to re-parse (the eviction source in between), so this compares two
	 * genuinely different roots reached through two different projection orders.
	 */
	public function testSharedRootSurvivesProjectionInAnyOrder(): Void {
		final forward: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final reverse: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final src: String = 'import haxe.io.Bytes;\n\nclass OrderProbe<T> {\n\tvar a: Bytes;\n\n'
			+ '\tfunction f(v: T): Int {\n\t\treturn cast(v, Int);\n\t}\n}';

		final tree: String = shapeOf(forward.parseFile(src));
		final refs: String = shapeOf(forward.parseFileTypeRefs(src));
		final types: String = mapDigest(forward.spanTypeInfo(src).declaredTypes);
		final imports: String = mapDigest(forward.importMap(src));
		Assert.notEquals('', imports, 'the fixture fills importMap — the comparisons below are not vacuous');

		new CachingGrammarPlugin(new HaxeQueryPlugin()).parseFile('class OrderProbeEvict {}');

		Assert.equals(imports, mapDigest(reverse.importMap(src)), 'importMap first');
		Assert.equals(types, mapDigest(reverse.spanTypeInfo(src).declaredTypes), 'spanTypeInfo second');
		Assert.equals(refs, shapeOf(reverse.parseFileTypeRefs(src)), 'parseFileTypeRefs third');
		Assert.equals(tree, shapeOf(reverse.parseFile(src)), 'parseFile last');
		Assert.equals(1, reverse.rootParses, 'the reverse wrapper parsed that source exactly once');
	}

	/**
	 * `maxComplexity` is the one method here that memoises a DISK walk. The Haxe grammar answers it
	 * by walking up to a `checkstyle.json`, reading it and re-deriving the threshold, and
	 * `Complexity.run` asks it once per FILE: 851 walks and 851 JSON parses for one config on the
	 * Pony scope, and the reason memoising `HaxeNamingSupport.policyFor` alone bought nothing
	 * measurable on a FULL-ruleset run — the same walk-and-parse still happened once per file here.
	 *
	 * Observed by rewriting the config out from under the run, which is what makes both halves
	 * visible without a call counter: a sibling file in the SAME directory must still answer the
	 * OLD threshold (memoised, keyed by directory), and a NEW wrapper must answer the new one.
	 *
	 * That last assertion is the one invariant 1 is about (`docs/design-principles.md` § 2). The
	 * cache is an instance field, so its lifetime is one lint / fix run and never the process's;
	 * make it `static` and it is this assertion, and only this assertion, that fails.
	 */
	public function testMaxComplexityMemoizedPerDirectoryAndPerRun(): Void {
		final dir: String = CliFixture.writeDir('cgpmaxcx', [
			{
				name: 'checkstyle.json',
				source: '{"checks":[{"type":"CyclomaticComplexity","props":{"thresholds":[{"severity":"WARNING","complexity":10}]}}]}'
			}
		]);
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.equals(9, cached.maxComplexity('$dir/A.hx'));
		File.saveContent(
			'$dir/checkstyle.json',
			'{"checks":[{"type":"CyclomaticComplexity","props":{"thresholds":[{"severity":"WARNING","complexity":20}]}}]}'
		);
		Assert.equals(
			19, new HaxeQueryPlugin().maxComplexity('$dir/A.hx'), 'the rewrite reached disk - the assertions below are not vacuous'
		);
		Assert.equals(9, cached.maxComplexity('$dir/B.hx'), 'a sibling file resolves to the memoised entry of its own directory');
		Assert.equals(
			19, new CachingGrammarPlugin(new HaxeQueryPlugin()).maxComplexity('$dir/A.hx'), 'the memo is RUN-scoped, never the process\'s'
		);
		CliFixture.removeDir(dir);
	}

	/** Every source-taking projection of one source, in the order a lint run demands them. */
	private static function projectEveryWay(cached: CachingGrammarPlugin, source: String): Void {
		// The four results are deliberately discarded: this helper exists to DEMAND each
		// projection, and what the callers assert on is `rootParses` — how many times that
		// demand reached a real parse. Suppressed per line rather than worked around,
		// because the discard IS the point; a sink local would make the values read as if
		// they mattered.
		cached.parseFile(source); // noqa: unused-return-value
		cached.parseFileTypeRefs(source); // noqa: unused-return-value
		cached.spanTypeInfo(source); // noqa: unused-return-value
		cached.importMap(source); // noqa: unused-return-value
	}

	/** Kind, name and span of every node in document order - the fingerprint two projections must share. */
	private static function shapeOf(node: QueryNode): String {
		final buf: StringBuf = new StringBuf();
		appendShape(node, buf);
		return buf.toString();
	}

	/** One node of `shapeOf`, then its children - kept apart so the entry point can own the buffer. */
	private static function appendShape(node: QueryNode, buf: StringBuf): Void {
		final span: Null<Span> = node.span;
		buf.add(node.kind);
		buf.add('|');
		buf.add(node.name ?? '-');
		buf.add(span == null ? '|-(' : '|${span.from}:${span.to}(');
		for (child in node.children) appendShape(child, buf);
		buf.add(')');
	}

	/** Every entry of a map as one sorted string - two maps hold the same entries iff these match. */
	private static function mapDigest<K, V>(map: Map<K, V>): String {
		final rows: Array<String> = [for (k => v in map) '$k=$v'];
		rows.sort(Reflect.compare);
		return rows.join(';');
	}

}
