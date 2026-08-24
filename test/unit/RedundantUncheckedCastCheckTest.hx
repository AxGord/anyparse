package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantUncheckedCast;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `redundant-unchecked-cast` check: a single-argument `cast e` whose POSITION is written
 * exactly the type `e` is already declared to be, across the same four positions
 * `redundant-cast-type` reads — an annotated declaration initializer, a `return` under an
 * explicit return annotation, a call-argument slot whose parameter is written `T`, and a plain
 * `=` assignment to an annotated lvalue.
 *
 * Everything else fails closed, and the near-misses are grouped by which HALF of the comparison
 * they break. The POSITION half: a sub-expression parent (a ternary branch), a callee not
 * declared in the file, a `Dynamic` slot, an unannotated declaration. The OPERAND half: a
 * non-identifier operand, an inference-typed local, an optional parameter (body type `Null<T>`,
 * not the written `T`), a re-shadowed name. And the comparison itself: two differently-spelled
 * generics, which is the shape an unchecked cast most often exists FOR — the invariant-array
 * bridge — and the one this rule must never propose deleting. That fixture sits at position (a)
 * on purpose: at a call slot the generics veto would refuse it FIRST and the comparison would
 * never run, so the test would pass without exercising what it names.
 *
 * The checked `cast(e, T)` and the `(e : T)` ascription are different kinds and are never seen.
 */
class RedundantUncheckedCastCheckTest extends Test {

	public function testAnnotatedLocalFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Foo) { final a:Foo = cast v; } }').length);
	}

	public function testAnnotatedVarLocalFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Foo) { var a:Foo = cast v; } }').length);
	}

	public function testVarMoreContinuationFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Foo) { var a:Int = 1, b:Foo = cast v; } }').length);
	}

	public function testReturnUnderAnnotatedFunctionFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Foo):Foo { return cast v; } }').length);
	}

	public function testCallArgumentFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function g(a:Foo, b:Int) {} function f(v:Foo) { g(cast v, 1); } }').length);
	}

	public function testAssignmentToAnnotatedFieldFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { var a:Foo; function f(v:Foo) { this.a = cast v; } }').length);
	}

	public function testTokenIdenticalGenericFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Array<Foo>) { final a:Array<Foo> = cast v; } }').length);
	}

	public function testSeverityIsInfo(): Void {
		Assert.equals(Severity.Info, violations('class Foo {} class C { function f(v:Foo) { final a:Foo = cast v; } }')[0].severity);
	}

	public function testDifferentTypeNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class Bar {} class C { function f(v:Bar) { final a:Foo = cast v; } }').length);
	}

	public function testDifferentlySpelledGenericsNotFlagged(): Void {
		// The invariant-array bridge an unchecked cast exists for: `Array<Bar>` into an
		// `Array<Foo>` slot. Position (a), so the comparison itself is what refuses it.
		Assert.equals(
			0, violations('class Foo {} class Bar {} class C { function f(v:Array<Bar>) { final a:Array<Foo> = cast v; } }').length
		);
	}

	public function testCheckedCastFormNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Foo) { final a:Foo = cast(v, Foo); } }').length);
	}

	public function testAscriptionNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Foo) { final a:Foo = (v : Foo); } }').length);
	}

	public function testDynamicPositionNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(v:Dynamic) { final a:Dynamic = cast v; } }').length);
	}

	public function testUnannotatedDeclarationNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Foo) { final a = cast v; } }').length);
	}

	public function testTernaryBranchNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Foo, o:Foo, c:Bool) { final a:Foo = c ? cast v : o; } }').length);
	}

	public function testForeignCalleeNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Foo) { unknownG(cast v, 1); } }').length);
	}

	public function testNonIdentifierOperandNotFlagged(): Void {
		Assert.equals(
			0, violations('class Foo {} class C { function g():Foo return null; function f() { final a:Foo = cast g(); } }').length
		);
	}

	public function testInferenceTypedOperandNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f() { var v = mk(); final a:Foo = cast v; } }').length);
	}

	public function testOptionalParameterOperandNotFlagged(): Void {
		// An optional parameter's body type is `Null<Foo>`, not the written `Foo`.
		Assert.equals(0, violations('class Foo {} class C { function f(?v:Foo) { final a:Foo = cast v; } }').length);
	}

	public function testReshadowedOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class Foo {} class Bar {} class C { function f() { var v:Bar = null; var v:Foo = null; final a:Foo = cast v; } }')
				.length
		);
	}

	public function testCommentInDeletedHeadNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Foo) { final a:Foo = cast /* why */ v; } }').length);
	}

	public function testFixUnwrapsToOperand(): Void {
		final out: String = applyFix('class Foo {} class C { function f(v:Foo) { final a:Foo = cast v; } }');
		Assert.isTrue(out.indexOf('final a:Foo = v;') != -1, 'expected `final a:Foo = v;`, got: $out');
	}

	public function testFixUnwrapsCallArgument(): Void {
		final out: String = applyFix('class Foo {} class C { function g(a:Foo, b:Int) {} function f(v:Foo) { g(cast v, 1); } }');
		Assert.isTrue(out.indexOf('g(v, 1)') != -1, 'expected `g(v, 1)`, got: $out');
	}

	public function testFixLeavesUnflaggedCastAlone(): Void {
		final src: String = 'class Foo {} class Bar {} class C { function f(v:Bar) { final a:Foo = cast v; } }';
		final check: RedundantUncheckedCast = new RedundantUncheckedCast();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testIsNotDefaultOff(): Void {
		Assert.isFalse(new RedundantUncheckedCast() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-unchecked-cast'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-unchecked-cast'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantUncheckedCast().run(
				[{ file: 'Bad.hx', source: 'class Bad { function f() { final a:Foo = cast ' }], new HaxeQueryPlugin()
			)
				.length
		);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new RedundantUncheckedCast(), src);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantUncheckedCast().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
