package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.Meta;
import anyparse.query.Meta.MetaHit;
import anyparse.query.QueryNode;
import anyparse.query.format.Json;

using Lambda;

/**
 * `Meta.find` walks a parsed QueryNode tree and collects every
 * annotation node, attributing each to the declaration it sits on per
 * the plugin's `MetaShape`.
 *
 * Covers Slice 4.1:
 *  - Member annotation attributes to the member decl, not the class.
 *  - Top-level annotation attributes to the type decl.
 *  - Paren-bearing `@:name(args)` arguments slice to source text.
 *  - Multiple annotations on one decl each resolve to that decl.
 *  - Adjacent annotated members resolve to their own decls.
 *  - Non-annotated decls produce no hits.
 *  - Expression-level metadata falls back to its enclosing decl
 *    (documented v1 behaviour).
 */
class ApqMetaTest extends Test {

	public function testMemberAnnotationAttributesToMember(): Void {
		final hits: Array<MetaHit> = findIn('class X { @:foo var n:Int; }');
		Assert.equals(1, hits.length, 'one annotation hit expected — got ${describe(hits)}');
		Assert.equals('@:foo', hits[0].annotation);
		Assert.equals('VarMember', hits[0].declKind, 'must attach to the member, not the class — got ${describe(hits)}');
		Assert.equals('n', hits[0].declName);
		Assert.equals(0, hits[0].args.length, 'paren-less annotation has no args');
	}

	public function testTopLevelAnnotationAttributesToTypeDecl(): Void {
		final hits: Array<MetaHit> = findIn('@:foo class X {}');
		Assert.equals(1, hits.length, 'one annotation hit expected — got ${describe(hits)}');
		Assert.equals('@:foo', hits[0].annotation);
		Assert.equals('ClassDecl', hits[0].declKind);
		Assert.equals('X', hits[0].declName);
	}

	public function testParenBearingArgsSliceToSource(): Void {
		final hits: Array<MetaHit> = findIn('class X { @:foo(a, b) var n:Int; }');
		Assert.equals(1, hits.length, 'one annotation hit expected — got ${describe(hits)}');
		Assert.equals('@:foo', hits[0].annotation, 'tag truncated before `(`');
		Assert.equals(2, hits[0].args.length, 'two args expected — got ${describe(hits)}');
		Assert.equals('a', hits[0].args[0]);
		Assert.equals('b', hits[0].args[1]);
	}

	public function testMultipleAnnotationsOnOneDecl(): Void {
		final hits: Array<MetaHit> = findIn('class X { @:a @:b var n:Int; }');
		Assert.equals(2, hits.length, 'two annotation hits expected — got ${describe(hits)}');
		Assert.equals('@:a', hits[0].annotation);
		Assert.equals('@:b', hits[1].annotation);
		for (h in hits) {
			Assert.equals('VarMember', h.declKind, 'both attach to the member — got ${describe(hits)}');
			Assert.equals('n', h.declName);
		}
	}

	public function testAdjacentMembersResolveToOwnDecls(): Void {
		final hits: Array<MetaHit> = findIn('class X { @:a var n:Int; @:b function y():Void {} }');
		Assert.equals(2, hits.length, 'one hit per member — got ${describe(hits)}');
		final a: Null<MetaHit> = hits.find(h -> h.annotation == '@:a');
		final b: Null<MetaHit> = hits.find(h -> h.annotation == '@:b');
		Assert.notNull(a);
		Assert.notNull(b);
		if (a != null) {
			Assert.equals('VarMember', a.declKind);
			Assert.equals('n', a.declName);
		}
		if (b != null) {
			Assert.equals('FnMember', b.declKind);
			Assert.equals('y', b.declName);
		}
	}

	public function testNonAnnotatedDeclProducesNoHits(): Void {
		final hits: Array<MetaHit> = findIn('class X { var n:Int; }');
		Assert.equals(0, hits.length, 'no annotations — got ${describe(hits)}');
	}

	public function testHitsCarryPositiveSpans(): Void {
		final hits: Array<MetaHit> = findIn('class X { @:foo var n:Int; }');
		for (h in hits) {
			final ms: Null<anyparse.runtime.Span> = h.metaSpan;
			final ds: Null<anyparse.runtime.Span> = h.declSpan;
			Assert.notNull(ms, 'annotation span expected');
			Assert.notNull(ds, 'decl span expected');
			if (ms != null) Assert.isTrue(ms.from >= 0 && ms.to >= ms.from, 'meta span well-formed');
			if (ds != null) Assert.isTrue(ds.from >= 0 && ds.to >= ds.from, 'decl span well-formed');
		}
	}

	public function testExpressionMetaFallsBackToEnclosingDecl(): Void {
		// v1 documented behaviour: expression-level `@:foo expr` has no
		// following decl-host sibling, so it attributes to the nearest
		// enclosing decl-host (the function), not a finer expr target.
		final hits: Array<MetaHit> = findIn('class X { static function f():Void { @:foo g(); } }');
		Assert.isTrue(hits.length >= 1, 'expression metadata still surfaces — got ${describe(hits)}');
		final h: MetaHit = hits[0];
		Assert.equals('@:foo', h.annotation);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isTrue(
			plugin.metaShape().declHostKinds.contains(h.declKind),
			'expression meta attributes to an enclosing decl-host — got ${h.declKind}'
		);
	}

	public function testJsonRenderShapeMatchesSpec(): Void {
		final source: String = 'class X { @:foo(a, b) var n:Int; }';
		final hits: Array<MetaHit> = findIn(source);
		final out: String = Json.renderMeta([{ file: 'x.hx', source: source, hits: hits }]);
		Assert.isTrue(out.indexOf('"hits"') >= 0, 'envelope key present — got $out');
		Assert.isTrue(out.indexOf('"annotation":"@:foo"') >= 0, 'annotation key/value — got $out');
		Assert.isTrue(out.indexOf('"args"') >= 0, 'args array key — got $out');
		Assert.isTrue(out.indexOf('"a"') >= 0 && out.indexOf('"b"') >= 0, 'arg values — got $out');
		Assert.isTrue(out.indexOf('"decl"') >= 0, 'decl object — got $out');
		Assert.isTrue(out.indexOf('"kind":"VarMember"') >= 0, 'decl kind — got $out');
		Assert.isTrue(out.indexOf('"name":"n"') >= 0, 'decl name — got $out');
		Assert.isTrue(out.indexOf('"span"') >= 0, 'decl span present — got $out');
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
