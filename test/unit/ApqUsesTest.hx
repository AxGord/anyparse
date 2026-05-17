package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.QueryNode;
import anyparse.query.Uses;
import anyparse.query.Uses.UsesHit;

using Lambda;

/**
 * `Uses.find` walks a `parseFileTypeRefs` tree and collects every
 * type-position reference matching the target name — the sister of
 * `ApqRefsTest` for the type axis (`apq uses`).
 *
 * Covers:
 *  - field / var type annotation, enum-ctor parameter type,
 *    function parameter type;
 *  - parameterized type reports both the head and each parameter
 *    (`Array<HxVarMore>` → `Array` + `HxVarMore`);
 *  - gating by construction: the default `parseFile` tree carries NO
 *    type-ref nodes, so `Uses.find` over it is always empty (this is
 *    what keeps `ast`/`search`/`refs`/`meta` byte-identical).
 */
class ApqUsesTest extends Test {

	public function testVarFieldTypeAnnotation():Void {
		final hits:Array<UsesHit> = usesIn('class X { var m:HxVarMore; }', 'HxVarMore');
		Assert.equals(1, hits.length, 'one type ref expected, got ${describe(hits)}');
	}

	public function testEnumCtorParamType():Void {
		final hits:Array<UsesHit> = usesIn('enum E { Ctor(d:HxVarDecl); }', 'HxVarDecl');
		Assert.equals(1, hits.length, 'enum-ctor param type expected, got ${describe(hits)}');
	}

	public function testFunctionParamType():Void {
		final hits:Array<UsesHit> = usesIn('class X { function f(p:HxVarDecl):Void {} }', 'HxVarDecl');
		Assert.equals(1, hits.length, 'fn-param type expected, got ${describe(hits)}');
	}

	public function testTypedefAnonFieldType():Void {
		final hits:Array<UsesHit> = usesIn('typedef T = { var m:HxVarMore; }', 'HxVarMore');
		Assert.isTrue(hits.length >= 1, 'anon-field type expected, got ${describe(hits)}');
	}

	public function testParameterizedTypeReportsHeadAndParam():Void {
		final tree:QueryNode = treeOf('class X { var m:Array<HxVarMore>; }');
		final shape:TypeRefShape = new HaxeQueryPlugin().typeRefShape();
		Assert.equals(1, Uses.find('Array', tree, shape).length, 'head type Array expected');
		Assert.equals(1, Uses.find('HxVarMore', tree, shape).length, 'param type HxVarMore expected');
	}

	public function testNoSpuriousHitWhenUntyped():Void {
		final hits:Array<UsesHit> = usesIn('class X { static function a() { var n = 0; } }', 'Int');
		Assert.equals(0, hits.length, 'no type annotation → no hit, got ${describe(hits)}');
	}

	public function testReturnTypeAnnotation():Void {
		// return types reach the tree as `Named` (not the dropped `type`
		// path) — `typeRefShape` lists `Named` so `uses` still finds them.
		final hits:Array<UsesHit> = usesIn('class X { function f():HxVarDecl return null; }', 'HxVarDecl');
		Assert.isTrue(hits.length >= 1, 'return type expected, got ${describe(hits)}');
	}

	public function testExtendsHeritage():Void {
		final hits:Array<UsesHit> = usesIn('class X extends HxVarDecl {}', 'HxVarDecl');
		Assert.isTrue(hits.length >= 1, 'extends heritage expected, got ${describe(hits)}');
	}

	public function testNewExpr():Void {
		final hits:Array<UsesHit> = usesIn('class X { static function a() { var n = new HxVarDecl(); } }', 'HxVarDecl');
		Assert.isTrue(hits.length >= 1, 'new T() expected, got ${describe(hits)}');
	}

	// ======== Gating by construction ========

	public function testDefaultParseFileTreeHasNoTypeRefs():Void {
		// The default projection (consumed by ast/search/refs/meta) must
		// NOT carry type-ref nodes — otherwise those four would regress.
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree:QueryNode = plugin.parseFile('class X { var m:HxVarMore; }');
		Assert.equals(0, Uses.find('HxVarMore', tree, plugin.typeRefShape()).length,
			'default parseFile tree must expose no TypeRef nodes');
	}

	// ======== Helpers ========

	private static function treeOf(source:String):QueryNode {
		return new HaxeQueryPlugin().parseFileTypeRefs(source);
	}

	private static function usesIn(source:String, name:String):Array<UsesHit> {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		return Uses.find(name, plugin.parseFileTypeRefs(source), plugin.typeRefShape());
	}

	private static function describe(hits:Array<UsesHit>):String {
		return '[' + hits.map(h -> '${h.name}@${h.span.from}-${h.span.to}').join(', ') + ']';
	}
}
