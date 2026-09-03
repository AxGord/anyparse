package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.QueryNode;
import anyparse.query.Uses;
import utest.Assert;
import utest.Test;

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

	public function testVarFieldTypeAnnotation(): Void {
		final hits: Array<UsesHit> = usesIn('class X { var m:HxVarMore; }', 'HxVarMore');
		Assert.equals(1, hits.length, 'one type ref expected, got ${describe(hits)}');
	}

	public function testEnumCtorParamType(): Void {
		final hits: Array<UsesHit> = usesIn('enum E { Ctor(d:HxVarDecl); }', 'HxVarDecl');
		Assert.equals(1, hits.length, 'enum-ctor param type expected, got ${describe(hits)}');
	}

	public function testFunctionParamType(): Void {
		final hits: Array<UsesHit> = usesIn('class X { function f(p:HxVarDecl):Void {} }', 'HxVarDecl');
		Assert.equals(1, hits.length, 'fn-param type expected, got ${describe(hits)}');
	}

	public function testTypedefAnonFieldType(): Void {
		final hits: Array<UsesHit> = usesIn('typedef T = { var m:HxVarMore; }', 'HxVarMore');
		Assert.isTrue(hits.length >= 1, 'anon-field type expected, got ${describe(hits)}');
	}

	public function testParameterizedTypeReportsHeadAndParam(): Void {
		final tree: QueryNode = treeOf('class X { var m:Array<HxVarMore>; }');
		final shape: TypeRefShape = new HaxeQueryPlugin().typeRefShape();
		Assert.equals(1, Uses.find('Array', tree, shape).length, 'head type Array expected');
		Assert.equals(1, Uses.find('HxVarMore', tree, shape).length, 'param type HxVarMore expected');
	}

	public function testNoSpuriousHitWhenUntyped(): Void {
		final hits: Array<UsesHit> = usesIn('class X { static function a() { var n = 0; } }', 'Int');
		Assert.equals(0, hits.length, 'no type annotation → no hit, got ${describe(hits)}');
	}

	public function testReturnTypeAnnotation(): Void {
		// return types reach the tree as `Named` (not the dropped `type`
		// path) — `typeRefShape` lists `Named` so `uses` still finds them.
		final hits: Array<UsesHit> = usesIn('class X { function f():HxVarDecl return null; }', 'HxVarDecl');
		Assert.isTrue(hits.length >= 1, 'return type expected, got ${describe(hits)}');
	}

	public function testExtendsHeritage(): Void {
		final hits: Array<UsesHit> = usesIn('class X extends HxVarDecl {}', 'HxVarDecl');
		Assert.isTrue(hits.length >= 1, 'extends heritage expected, got ${describe(hits)}');
	}

	public function testNewExpr(): Void {
		final hits: Array<UsesHit> = usesIn('class X { static function a() { var n = new HxVarDecl(); } }', 'HxVarDecl');
		Assert.isTrue(hits.length >= 1, 'new T() expected, got ${describe(hits)}');
	}

	public function testArrowFnParamNameIsNotATypeRef(): Void {
		// `HxArrowParam.Named(body)` shares its ctor name with `HxType.Named`,
		// but only the latter fronts a `type` slot: the parameter NAME of a
		// new-form arrow type must stay out of the projection while the
		// parameter's own TYPE stays in it.
		final source: String = 'class X { var cb:(p:HxVarDecl, q:Int) -> Void; }';
		final names: Array<UsesHit> = usesIn(source, 'p');
		final types: Array<UsesHit> = usesIn(source, 'HxVarDecl');
		Assert.equals(0, names.length, 'arrow-fn param name must not project as a type ref, got ${describe(names)}');
		Assert.equals(1, types.length, 'the named param type must still project, got ${describe(types)}');
		Assert.equals(1, usesIn(source, 'Int').length, 'the second param type must still project');
	}

	public function testOptionalArrowFnParamNameIsNotATypeRef(): Void {
		final source: String = 'class X { var cb:(?p:HxVarDecl) -> Void; }';
		final names: Array<UsesHit> = usesIn(source, 'p');
		final types: Array<UsesHit> = usesIn(source, 'HxVarDecl');
		Assert.equals(0, names.length, 'optional arrow-fn param name must not project as a type ref, got ${describe(names)}');
		Assert.equals(1, types.length, 'the optional param type must still project, got ${describe(types)}');
	}

	public function testArrowFnParamNameInAReturnTypeIsNotATypeRef(): Void {
		// The same arrow type in a RETURN slot reaches the tree through `_walk`, not
		// `_typeRefs`: there the ctor NAME is the node kind, and `typeRefShape` lists
		// `Named` — so qualifying the `_typeRefs` emit alone left the parameter label
		// reported as a type reference on this second path.
		final source: String = 'class X { function f():(p:HxVarDecl) -> Void { return null; } }';
		final names: Array<UsesHit> = usesIn(source, 'p');
		final types: Array<UsesHit> = usesIn(source, 'HxVarDecl');
		Assert.equals(0, names.length, 'return-type arrow param name must not project as a type ref, got ${describe(names)}');
		Assert.equals(1, types.length, 'the param type must still project, got ${describe(types)}');
	}

	public function testAnonInsideATypeParameterProjects(): Void {
		// An anon struct in a type-PARAMETER slot reaches `_typeRefs`, not the
		// decl-host descent in `_walk`, so before the `Anon` arm recursed every
		// nominal name inside the braces was dropped with the whole struct.
		assertAnonFieldTypeProjects('class X { var a:Array<{ f:HxVarDecl }>; }', 'Array type param');
		assertAnonFieldTypeProjects('class X { var a:Map<String, { f:HxVarDecl }>; }', 'Map value param');
		assertAnonFieldTypeProjects('class X { var a:Null<{ f:HxVarDecl }>; }', 'Null param');
		assertAnonFieldTypeProjects('class X { var a:Array<Array<{ f:HxVarDecl }>>; }', 'nested Array param');
		assertAnonFieldTypeProjects('typedef T = Array<{ f:HxVarDecl }>;', 'typedef RHS type param');
	}

	public function testAnonInAnOperandPositionProjects(): Void {
		// Same loss on every `HxType` ctor that carries an operand: the arrow
		// operands, the parens atom and the `?` optional-arg marker.
		assertAnonFieldTypeProjects('class X { var a:{ f:HxVarDecl } -> Void; }', 'old-form arrow operand');
		assertAnonFieldTypeProjects('class X { var a:(q:{ f:HxVarDecl }) -> Void; }', 'new-form arrow parameter');
		assertAnonFieldTypeProjects('class X { var a:({ f:HxVarDecl }); }', 'parenthesised type');
		assertAnonFieldTypeProjects('class X { var a:?{ f:HxVarDecl }; }', 'optional-arg marker');
		assertAnonFieldTypeProjects('typedef T = { f:HxVarDecl } -> Void;', 'typedef RHS arrow operand');
	}

	public function testAnonInAnOptionalParameterProjects(): Void {
		final source: String = 'class X { function m(?p:Array<{ f:HxVarDecl }>):Void {} }';
		assertAnonFieldTypeProjects(source, 'optional fn param');
		Assert.equals(0, usesIn(source, 'p').length, 'the optional parameter name must stay out of the projection');
	}

	public function testEveryNominalInsideAnAnonProjects(): Void {
		// The whole struct was dropped, so a parameterized field type lost its
		// head and its own parameters along with the field type.
		final source: String = 'class X { var a:Array<{ inner:Map<String, HxVarDecl> }>; }';
		Assert.equals(1, usesIn(source, 'Array').length, 'the enclosing Array must still project');
		Assert.equals(1, usesIn(source, 'Map').length, 'the anon field head Map expected, got ${describe(usesIn(source, 'Map'))}');
		Assert.equals(
			1, usesIn(source, 'String').length, 'the anon field key param String expected, got ${describe(usesIn(source, 'String'))}'
		);
		Assert.equals(
			1, usesIn(source, 'HxVarDecl').length, 'the anon field value param expected, got ${describe(usesIn(source, 'HxVarDecl'))}'
		);
	}

	public function testAnonFieldNameIsNotATypeRef(): Void {
		// `Naming` DISCOUNTS the type-ref spans from its completeness gate, so a
		// field name leaking into the projection would silently orphan a real
		// value reference of the same name.
		final source: String = 'class X { var a:Array<{ node:HxVarDecl }>; }';
		final names: Array<UsesHit> = usesIn(source, 'node');
		final types: Array<UsesHit> = usesIn(source, 'HxVarDecl');
		Assert.equals(0, names.length, 'anon field name must not project as a type ref, got ${describe(names)}');
		Assert.equals(1, types.length, 'the anon field type must project, got ${describe(types)}');
	}

	public function testNestedAnonReportsEachTypeExactlyOnce(): Void {
		// `seqFieldDescent` picks EITHER the decl-host descent OR the type-ref
		// call, never both — an anon nested in an anon must not double-report.
		final direct: Array<UsesHit> = usesIn('class X { var a:{ outer:{ inner:HxVarDecl } }; }', 'HxVarDecl');
		final viaParam: Array<UsesHit> = usesIn('class X { var a:Array<{ outer:{ inner:HxVarDecl } }>; }', 'HxVarDecl');
		Assert.equals(1, direct.length, 'anon-in-anon in a type slot expected once, got ${describe(direct)}');
		Assert.equals(1, viaParam.length, 'anon-in-anon in a type param expected once, got ${describe(viaParam)}');
	}

	// ======== Gating by construction ========

	public function testDefaultParseFileTreeHasNoTypeRefs(): Void {
		// The default projection (consumed by ast/search/refs/meta) must
		// NOT carry type-ref nodes — otherwise those four would regress.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile('class X { var m:HxVarMore; }');
		Assert.equals(0, Uses.find('HxVarMore', tree, plugin.typeRefShape()).length, 'default parseFile tree must expose no TypeRef nodes');
	}

	// ======== Helpers ========

	private static function treeOf(source: String): QueryNode {
		return new HaxeQueryPlugin().parseFileTypeRefs(source);
	}

	private static function usesIn(source: String, name: String): Array<UsesHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Uses.find(name, plugin.parseFileTypeRefs(source), plugin.typeRefShape());
	}

	private static function assertAnonFieldTypeProjects(source: String, label: String): Void {
		final hits: Array<UsesHit> = usesIn(source, 'HxVarDecl');
		Assert.equals(1, hits.length, '$label: the anon field type must project exactly once, got ${describe(hits)}');
	}

	private static function describe(hits: Array<UsesHit>): String {
		return '[${hits.map(h -> '${h.name}@${h.span.from}-${h.span.to}').join(', ')}]';
	}

}
