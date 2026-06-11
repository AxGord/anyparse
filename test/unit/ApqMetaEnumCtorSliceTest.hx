package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.Meta;
import anyparse.query.Meta.MetaHit;
import anyparse.query.QueryNode;

using Lambda;

/**
 * apq P5 query-value Slice (#1a): `meta` on enum-constructor
 * annotations.
 *
 * Slice I made `enum E { @:kw('x') A; }` parse (parse-rate, +17),
 * but `DECL_HOST_KINDS` (shared by `metaShape`) never listed the
 * `SimpleCtor` / `ParamCtor` host kinds — so `apq meta @:kw
 * <grammarfile>` returned 0 hits despite real enum-ctor annotations
 * (the `MetaCall` and ctor nodes flatten as spanned siblings, but
 * `Meta.followingDeclHost` had no host kind to resolve to and the
 * direct-child meta-scan at the EnumDecl boundary sees a null
 * ancestor, so the hit was dropped entirely — not even an EnumDecl
 * fallback).
 *
 * Pre-fix these assertions are RED (0 hits); post-fix GREEN.
 */
class ApqMetaEnumCtorSliceTest extends Test {

	public function testZeroArgCtorAnnotationAttributesToSimpleCtor(): Void {
		final hits: Array<MetaHit> = findIn('enum E { @:kw("var") A; B(x:Int); }');
		final kw: Null<MetaHit> = hits.find(h -> h.annotation == '@:kw');
		Assert.notNull(kw, '@:kw on enum ctor must surface — got ${describe(hits)}');
		if (kw != null) {
			Assert.equals('SimpleCtor', kw.declKind, 'attributes to the zero-arg ctor — got ${describe(hits)}');
			Assert.equals('A', kw.declName);
			Assert.equals(1, kw.args.length, 'one arg expected — got ${describe(hits)}');
			Assert.isTrue(kw.args[0].indexOf('var') >= 0, 'arg slices the source string — got ${describe(hits)}');
		}
	}

	public function testParamCtorAnnotationAttributesToParamCtor(): Void {
		final hits: Array<MetaHit> = findIn('enum E { @:foo B(x:Int); }');
		final foo: Null<MetaHit> = hits.find(h -> h.annotation == '@:foo');
		Assert.notNull(foo, '@:foo on a param-bearing ctor must surface — got ${describe(hits)}');
		if (foo != null) {
			Assert.equals('ParamCtor', foo.declKind, 'attributes to the param ctor — got ${describe(hits)}');
			Assert.equals('B', foo.declName);
		}
	}

	public function testMultipleEnumCtorAnnotationsEachResolve(): Void {
		final hits: Array<MetaHit> = findIn('enum E { @:kw("if") If; @:kw("for") For; Plain; }');
		final kws: Array<MetaHit> = hits.filter(h -> h.annotation == '@:kw');
		Assert.equals(2, kws.length, 'each enum-ctor @:kw resolves — got ${describe(hits)}');
		Assert.isTrue(kws.exists(h -> h.declName == 'If'), 'If ctor annotation — got ${describe(hits)}');
		Assert.isTrue(kws.exists(h -> h.declName == 'For'), 'For ctor annotation — got ${describe(hits)}');
	}

	public function testUnannotatedEnumCtorNoHit(): Void {
		final hits: Array<MetaHit> = findIn('enum E { A; B(x:Int); }');
		Assert.equals(0, hits.length, 'no annotations means no hits — got ${describe(hits)}');
	}

	private static function findIn(source: String): Array<MetaHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: MetaShape = plugin.metaShape();
		return Meta.find(tree, shape, source);
	}

	private static function describe(hits: Array<MetaHit>): String {
		return '[' + hits.map(h -> '${h.annotation}(${h.args.join("|")})@${h.declKind}:${h.declName ?? "?"}').join(', ') + ']';
	}

}
