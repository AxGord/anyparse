package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.format.Text;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A `var` / `final` declaration's type annotation is reachable from the declaration node.
 *
 * Before this slice `final arr:Array<CodePoint> = mk();` projected
 * `(FinalStmt arr (Call (IdentExpr mk)))` — the annotation contributed NO node at all,
 * not the type argument and not even the bare head. Every consumer that needed the
 * declared type read it back out of the source text: `prefer-for-in` matched a regex
 * over the declaration's head slice, and `explicit-local-type` — a rule that WRITES
 * annotations — could not lean on the tree either.
 *
 * It arrives in the `QueryNode.type` SLOT rather than among the children, because a
 * declaration's children are its initializer and its comma-continuations and some forty
 * rules read them positionally. The slot's subtree is the type's own shape: kind = the
 * `HxType` ctor, name = the nominal head, children = the type ARGUMENTS.
 */
@:nullSafety(Strict)
class LocalTypeAnnotationProjectionTest extends Test {

	/** The motivating case: a parameterised annotation on a local, head and argument both reachable. */
	public function testLocalFinalProjectsHeadAndTypeArgument(): Void {
		final decl: QueryNode = declOf('class C { function f() { final arr:Array<CodePoint> = mk(); } }');
		final declared: Null<QueryNode> = decl.type;
		Assert.notNull(declared, 'the declaration must carry its annotation');
		if (declared == null) return;
		Assert.equals('Named', declared.kind);
		Assert.equals('Array', declared.name);
		Assert.equals(1, declared.children.length, 'one type argument');
		Assert.equals('CodePoint', declared.children[0].name);
	}

	/** A bare annotation projects the head alone — no phantom argument node. */
	public function testLocalFinalProjectsBareType(): Void {
		final declared: Null<QueryNode> = declOf('class C { function f() { final plain:CodePoint = one(); } }').type;
		Assert.notNull(declared);
		if (declared == null) return;
		Assert.equals('CodePoint', declared.name);
		Assert.equals(0, declared.children.length);
	}

	/** Every argument, in source order, under the one head. */
	public function testLocalVarProjectsEveryArgumentInSourceOrder(): Void {
		final dump: String = ast('class C { function f() { var m:Map<String, Int> = new Map(); } }');
		Assert.isTrue(dump.contains('(VarStmt m (: (Named Map (Named String) (Named Int))) (NewExpr Map))'), 'got: $dump');
	}

	/** THE WHOLE POINT: the children of a declaration do not move. */
	public function testAnnotationDoesNotDisplaceTheInitializer(): Void {
		final decl: QueryNode = declOf('class C { function f() { var t:Int = 1; } }');
		Assert.equals(1, decl.children.length, 'the initializer is still the sole child');
		Assert.equals('IntLit', decl.children[0].kind, 'and still the FIRST one');
	}

	/** An un-annotated declaration keeps its empty slot — nothing is invented. */
	public function testUnannotatedDeclarationHasNoType(): Void {
		final decl: QueryNode = declOf('class C { function f() { var u = mk(); } }');
		Assert.isNull(decl.type);
		Assert.equals(1, decl.children.length);
	}

	/**
	 * An anon annotation keeps the decl-host child it already had — that descent is how
	 * an anon field becomes a declaration `refs` can resolve — and gains the slot beside it.
	 */
	public function testAnonAnnotationKeepsItsDeclHostChild(): Void {
		final decl: QueryNode = declOf('class C { function f() { var s:{a:Int} = mk(); } }');
		Assert.equals(2, decl.children.length, 'the pre-slice Anon child survives');
		Assert.equals('Anon', decl.children[0].kind);
		final declared: Null<QueryNode> = decl.type;
		Assert.notNull(declared);
		if (declared != null) Assert.equals('Anon', declared.kind);
	}

	/** The same slot serves a class member, so a field annotation projects too. */
	public function testClassMemberAnnotationProjects(): Void {
		final dump: String = ast('class C { var field:Array<Int>; }');
		Assert.isTrue(dump.contains('(VarMember field (: (Named Array (Named Int))))'), 'got: $dump');
	}

	/** Every binding after the first in a multi-var declaration carries its own annotation. */
	public function testMultiVarContinuationCarriesItsOwnAnnotation(): Void {
		final decl: QueryNode = declOf('class C { function f() { var a:Int = 1, b:String = "s"; } }');
		final head: Null<QueryNode> = decl.type;
		Assert.notNull(head, 'the head binding');
		if (head != null) Assert.equals('Int', head.name);
		final more: QueryNode = decl.children[decl.children.length - 1];
		Assert.equals('VarMore', more.kind);
		final tail: Null<QueryNode> = more.type;
		Assert.notNull(tail, 'the continuation');
		if (tail != null) Assert.equals('String', tail.name);
	}

	/**
	 * A function-type annotation is the case NO kind-based child filter could have handled:
	 * `Arrow` is `HxType.Arrow` here and `HxExpr.Arrow` (`k => v`) on an initializer, so only
	 * a slot can say which of the two a node is looking at.
	 */
	public function testFunctionTypeAnnotationIsUnambiguousInTheSlot(): Void {
		final decl: QueryNode = declOf('class C { function f() { var cb:Int->Void = null; } }');
		final declared: Null<QueryNode> = decl.type;
		Assert.notNull(declared);
		if (declared != null) Assert.equals('Arrow', declared.kind);
		Assert.equals(1, decl.children.length, 'the initializer is still the sole child');
		Assert.equals('NullLit', decl.children[0].kind);
	}

	/** A map-literal initializer keeps the SAME kind on the child, and the slot stays empty. */
	public function testMapArrowInitializerIsNotMistakenForAType(): Void {
		final decl: QueryNode = declOf('class C { function f() { var m = k => v; } }');
		Assert.isNull(decl.type);
		Assert.equals('Arrow', decl.children[0].kind);
	}

	/** A function PARAMETER carries its annotation in the same slot. */
	public function testParameterAnnotationProjects(): Void {
		final dump: String = ast('class C { function g(p:Map<String, Int>) {} }');
		Assert.isTrue(dump.contains('(Required p (: (Named Map (Named String) (Named Int))))'), 'got: $dump');
	}

	/** So does a CATCH binding. */
	public function testCatchBindingAnnotationProjects(): Void {
		final dump: String = ast('class C { function f() { try { a(); } catch (e:MyErr) { b(); } } }');
		Assert.isTrue(dump.contains('(CatchClause e (: (Named MyErr))'), 'got: $dump');
	}

	/** Type arguments nest under their head wherever a type already projected — a return type included. */
	public function testReturnTypeArgumentsNestUnderTheirHead(): Void {
		final dump: String = ast('class C { function g():Array<Foo> return null; }');
		Assert.isTrue(dump.contains('(Named Array (Named Foo))'), 'got: $dump');
	}

	/** The type-reference projection is untouched: it keeps its flat `TypeRef` run and grows no slot. */
	public function testTypeRefProjectionIsUnchanged(): Void {
		final src: String = 'class C { function f() { final arr:Array<CodePoint> = mk(); } }';
		final dump: String = Text.render(new HaxeQueryPlugin().parseFileTypeRefs(src));
		Assert.isTrue(dump.contains('(FinalStmt arr (TypeRef Array) (TypeRef CodePoint) (Call (IdentExpr mk)))'), 'got: $dump');
		Assert.isFalse(dump.contains('(: '), 'no slot in the type-reference tree, got: $dump');
	}

	/** The FIRST declaration node of the parsed source — the one every assertion above is about. */
	private static function declOf(source: String): QueryNode {
		final found: Null<QueryNode> = find(new HaxeQueryPlugin().parseFile(source));
		if (found == null) throw 'no declaration node in: $source';
		return found;
	}

	private static function find(node: QueryNode): Null<QueryNode> {
		if (node.kind == 'VarStmt' || node.kind == 'FinalStmt') return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = find(c);
			if (hit != null) return hit;
		}
		return null;
	}

	private static function ast(source: String): String return Text.render(new HaxeQueryPlugin().parseFile(source));

}
