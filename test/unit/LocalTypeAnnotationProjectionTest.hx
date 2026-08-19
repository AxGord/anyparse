package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.format.Text;

using StringTools;

/**
 * A `var` / `final` declaration's type annotation is a node in the default query tree.
 *
 * Before this slice `final arr:Array<CodePoint> = mk();` projected
 * `(FinalStmt arr (Call (IdentExpr mk)))` — the annotation contributed NO node at all,
 * not the type argument and not even the bare head. Every consumer that needed the
 * declared type had to read it back out of the source text: `prefer-for-in` matched a
 * regex over the declaration's head slice, and `explicit-local-type` — a rule that
 * WRITES annotations — could not lean on the tree either.
 *
 * `@:queryType` on `HxVarDecl.type` routes the slot through the SAME default `_walk`
 * that a function's return type and an `extends` clause already use, so the annotation
 * arrives as exactly ONE child whose kind is the `HxType` ctor (`Named` / `Anon` /
 * `Arrow` / `ArrowFn` / …). `@:queryType` on `HxTypeArg.type` nests the type ARGUMENTS
 * under their head, so `Array<CodePoint>` is `(Named Array (Named CodePoint))` rather
 * than a flat sibling run whose nesting cannot be recovered.
 */
@:nullSafety(Strict)
class LocalTypeAnnotationProjectionTest extends Test {

	/** The motivating case: a parameterised annotation on a local, head and argument both reachable. */
	public function testLocalFinalProjectsHeadAndTypeArgument(): Void {
		final dump: String = ast('class C { function f() { final arr:Array<CodePoint> = mk(); } }');
		Assert.isTrue(
			dump.contains('(FinalStmt arr (Named Array (Named CodePoint)) (Call (IdentExpr mk)))'),
			'the annotation must project as one child with its argument nested, got: $dump'
		);
	}

	/** A bare annotation projects the head alone — no phantom argument node. */
	public function testLocalFinalProjectsBareType(): Void {
		final dump: String = ast('class C { function f() { final plain:CodePoint = one(); } }');
		Assert.isTrue(dump.contains('(FinalStmt plain (Named CodePoint) (Call (IdentExpr one)))'), 'got: $dump');
	}

	/** `var` is the same slot as `final` — both host `HxVarDecl`. */
	public function testLocalVarProjectsEveryArgumentInSourceOrder(): Void {
		final dump: String = ast('class C { function f() { var m:Map<String, Int> = new Map(); } }');
		Assert.isTrue(dump.contains('(VarStmt m (Named Map (Named String) (Named Int)) (NewExpr Map))'), 'got: $dump');
	}

	/** An un-annotated declaration keeps exactly the children it had — the projection adds nothing. */
	public function testUnannotatedDeclarationIsUnchanged(): Void {
		final dump: String = ast('class C { function f() { var u = mk(); } }');
		Assert.isTrue(dump.contains('(VarStmt u (Call (IdentExpr mk)))'), 'got: $dump');
	}

	/** The annotation sorts BEFORE the initializer, as its span demands. */
	public function testAnnotationPrecedesTheInitializer(): Void {
		final dump: String = ast('class C { function f() { var t:Int = 1; } }');
		Assert.isTrue(dump.contains('(VarStmt t (Named Int) (IntLit 1))'), 'got: $dump');
	}

	/** An anon annotation still descends as a declaration host — the pre-slice behaviour it already had. */
	public function testAnonAnnotationStillDescends(): Void {
		final dump: String = ast('class C { function f() { var s:{a:Int} = mk(); } }');
		Assert.isTrue(dump.contains('(VarStmt s (Anon (Required a (TypeRef Int))) (Call (IdentExpr mk)))'), 'got: $dump');
	}

	/** The same slot serves a class member, so a field annotation projects too. */
	public function testClassMemberAnnotationProjects(): Void {
		final dump: String = ast('class C { var field:Array<Int>; }');
		Assert.isTrue(dump.contains('(VarMember field (Named Array (Named Int)))'), 'got: $dump');
	}

	/** Every binding after the first in a multi-var declaration carries its own annotation node. */
	public function testMultiVarContinuationCarriesItsOwnAnnotation(): Void {
		final dump: String = ast('class C { function f() { var a:Int = 1, b:String = "s"; } }');
		Assert.isTrue(dump.contains('(VarMore b (Named String) (DoubleStringExpr'), 'got: $dump');
	}

	/** Type arguments nest under their head wherever a type already projected — a return type included. */
	public function testReturnTypeArgumentsNestUnderTheirHead(): Void {
		final dump: String = ast('class C { function g():Array<Foo> return null; }');
		Assert.isTrue(dump.contains('(Named Array (Named Foo))'), 'got: $dump');
	}

	/** The type-reference projection is untouched: it keeps its flat `TypeRef` run. */
	public function testTypeRefProjectionKeepsItsFlatShape(): Void {
		final dump: String = Text.render(new HaxeQueryPlugin().parseFileTypeRefs('class C { function f() { final arr:Array<CodePoint> = mk(); } }'));
		Assert.isTrue(dump.contains('(FinalStmt arr (TypeRef Array) (TypeRef CodePoint) (Call (IdentExpr mk)))'), 'got: $dump');
	}

	private static function ast(source: String): String return Text.render(new HaxeQueryPlugin().parseFile(source));

}
