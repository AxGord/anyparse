package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Meta;
import anyparse.query.Meta.MetaHit;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;

using Lambda;

/**
 * apq P5 query-value Slice (#1b): typedef anon-struct field
 * metadata + binding.
 *
 * Slice C made `typedef T = { @:meta var x; }` parse (parse-rate,
 * +83 — anyparse's own grammar DSL shape), but `appendNodes`
 * unconditionally skipped the struct field literally named `type`
 * (a name-slot heuristic for `new T(...)` / `var x:Foo`). A
 * typedef's bound `HxType.Anon` body therefore never descended —
 * `TypedefDecl` surfaced with `children:[]`, so `apq meta` and
 * `apq refs` were both blind to anon-struct members.
 *
 * Fix: descend the `type` field when it is an `HxType.Anon` enum
 * (`isAnonType` gate — `Named`/`Arrow` type-refs stay skipped, no
 * phantom child per typed binding) + `VarField`/`FinalField`/
 * `FnField` host kinds. The 5 anon-surfacing tests are RED pre-fix
 * (0 hits / not a decl) → GREEN post-fix; the 2 blast-radius guards
 * (`Named` type-ref, alias typedef) are GREEN both sides and assert
 * the fix introduces NO spurious child.
 */
class ApqMetaAnonFieldSliceTest extends Test {

	public function testTypedefAnonVarFieldMetaSurfaces(): Void {
		final hits: Array<MetaHit> = metaIn('typedef T = { @:m1 var f:Int; };');
		final m: Null<MetaHit> = hits.find(h -> h.annotation == '@:m1');
		Assert.notNull(m, '@:m1 on anon var field must surface — got ${describe(hits)}');
		if (m != null) {
			Assert.equals('VarField', m.declKind, 'attributes to the anon var field — got ${describe(hits)}');
			Assert.equals('f', m.declName);
		}
	}

	public function testTypedefAnonFnFieldMetaSurfaces(): Void {
		final hits: Array<MetaHit> = metaIn('typedef T = { @:fn function g():Void; };');
		final m: Null<MetaHit> = hits.find(h -> h.annotation == '@:fn');
		Assert.notNull(m, '@:fn on anon function field must surface — got ${describe(hits)}');
		if (m != null) {
			Assert.equals('FnField', m.declKind, 'attributes to the anon fn field — got ${describe(hits)}');
			Assert.equals('g', m.declName);
		}
	}

	public function testBareAnonFieldMetaReusesRequiredHost(): Void {
		// `name:Type` (no var/final/function kw) → HxAnonField.Required,
		// already a decl-host via the HxParam entry. Only the `type`
		// descent was blocking it.
		final hits: Array<MetaHit> = metaIn('typedef T = { @:b x:Int; };');
		final m: Null<MetaHit> = hits.find(h -> h.annotation == '@:b');
		Assert.notNull(m, '@:b on bare anon field must surface — got ${describe(hits)}');
		if (m != null) Assert.equals('x', m.declName, 'attributes to the bare field x — got ${describe(hits)}');
	}

	public function testAnonFieldIsRefsDeclHost(): Void {
		final hits: Array<RefHit> = refsIn('typedef T = { var f:Int; };', 'f');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Decl), 'anon field `f` is a decl — got ${hits.length} hits');
	}

	public function testAnonInVarTypeHintMetaSurfaces(): Void {
		// Bonus from the generic Anon gate: anon body in a var type
		// hint also surfaces (not only typedef RHS).
		final hits: Array<MetaHit> = metaIn('class C { var h:{ @:m2 var k:Int; }; }');
		Assert.isTrue(hits.exists(h -> h.annotation == '@:m2'), '@:m2 in anon type-hint surfaces — got ${describe(hits)}');
	}

	public function testNamedTypeRefProducesNoPhantomChild(): Void {
		// Blast-radius guard: `var x:Foo` — `type` is HxType.Named, NOT
		// Anon, so it stays skipped. `Foo` must NOT surface as a decl
		// (no phantom child per typed binding).
		final hits: Array<RefHit> = refsIn('class C { var x:Foo; }', 'Foo');
		Assert.equals(0, hits.length, 'Named type-ref `Foo` must not surface as a node — got ${hits.length}');
	}

	public function testTypedefAliasNotAnonNoHit(): Void {
		final hits: Array<MetaHit> = metaIn('typedef T = Int;');
		Assert.equals(0, hits.length, 'plain alias typedef has no anon members — got ${describe(hits)}');
	}

	private static function metaIn(source: String): Array<MetaHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: MetaShape = plugin.metaShape();
		return Meta.find(tree, shape, source);
	}

	private static function refsIn(source: String, name: String): Array<RefHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: RefShape = plugin.refShape();
		return Refs.find(name, tree, shape);
	}

	private static function describe(hits: Array<MetaHit>): String {
		return '[' + hits.map(h -> '${h.annotation}@${h.declKind}:${h.declName ?? '?'}').join(', ') + ']';
	}

}
