package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantCastType;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-cast-type` check: a runtime-checked `cast(e, T)` whose POSITION is already
 * annotated exactly `T` — an annotated declaration initializer, a `return` under an explicit
 * return annotation, or a call-argument slot whose parameter is written `T`. Everything else
 * fails closed: no annotation, a differing type, a non-token-identical generic, the unchecked
 * `cast e` / the `(e : T)` ascription, a sub-expression position, a `Dynamic` target, and a
 * comment in either deleted region. Three families of near-miss carry their own fixtures, each
 * proven to fail when its gate is removed: a type-parameter CONSTRAINT read as a return type
 * (plain, structural, and behind a header comment); a nested function form resolving against the
 * OUTER annotation (lambda, `inline function`, `NamedFnExpr`, `untyped` body); and a call slot
 * whose positional mapping is unproven (a field-access callee, a generic callee, an optional or
 * defaulted parameter AHEAD of the slot — while one behind it still fires).
 */
class RedundantCastTypeCheckTest extends Test {

	public function testAnnotatedFinalLocalFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Dynamic) { final a:Foo = cast(v, Foo); } }').length);
	}

	public function testAnnotatedVarLocalFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Dynamic) { var a:Foo = cast(v, Foo); } }').length);
	}

	public function testAnnotatedVarFieldFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { var a:Foo = cast(v, Foo); }').length);
	}

	public function testAnnotatedFinalFieldFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { final a:Foo = cast(v, Foo); }').length);
	}

	public function testVarMoreContinuationFlagged(): Void {
		// The `VarMore` continuation carries its OWN annotation and its own initializer.
		Assert.equals(1, violations('class Foo {} class C { function f(v:Dynamic) { var a:Foo = cast(v, Foo), b:Int = 2; } }').length);
	}

	public function testReturnUnderAnnotatedFunctionFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Dynamic):Foo { return cast(v, Foo); } }').length);
	}

	public function testExpressionBodyReturnFlagged(): Void {
		Assert.equals(1, violations('class Foo {} class C { function f(v:Dynamic):Foo return cast(v, Foo); }').length);
	}

	public function testTokenIdenticalGenericFlagged(): Void {
		// `sameTypeSource` is whitespace-insensitive, so the differing spacing still matches.
		Assert.equals(1, violations('class C { function f(v:Dynamic) { final m:Map<String, Int> = cast(v, Map<String,Int>); } }').length);
	}

	public function testCallArgumentFlagged(): Void {
		Assert.equals(
			1, violations('class Foo {} class C { function g(a:Foo, b:Int) {} function f(v:Dynamic) { g(cast(v, Foo), 1); } }').length
		);
	}

	public function testImportReconciledSpellingFlagged(): Void {
		// `Eof` is imported, so the bare name and the qualified path canonicalize to one FQN.
		Assert.equals(
			1, violations('import haxe.io.Eof; class C { function f(v:Dynamic) { final e:haxe.io.Eof = cast(v, Eof); } }').length
		);
	}

	public function testUnannotatedLocalNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Dynamic) { final a = cast(v, Foo); } }').length);
	}

	public function testDifferingTypeNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class Bar {} class C { function f(v:Dynamic) { final a:Bar = cast(v, Foo); } }').length);
	}

	public function testDifferingGenericParamsNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f(v:Dynamic) { final m:Map<String, Int> = cast(v, Map<String, Float>); } }').length
		);
	}

	public function testUncheckedCastNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Dynamic) { final a:Foo = cast v; } }').length);
	}

	public function testAscriptionNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Dynamic) { final a:Foo = (v : Foo); } }').length);
	}

	public function testSubExpressionPositionNotFlagged(): Void {
		Assert.equals(
			0, violations('class Foo {} class C { function f(c:Bool, v:Dynamic, o:Foo) { final a:Foo = c ? cast(v, Foo) : o; } }').length
		);
	}

	public function testCommentInCastHeadNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(v:Dynamic) { final a:Foo = cast/* z */(v, Foo); } }').length);
	}

	public function testCommentInCastTailNotFlagged(): Void {
		// The `, T)` tail is the fix's second deleted region — a comment there suppresses too.
		Assert.equals(0, violations('class Foo {} class C { function f(v:Dynamic) { final a:Foo = cast(v, Foo /* z */); } }').length);
	}

	public function testReturnWithoutAnnotationNotFlagged(): Void {
		// The operand is written `Foo` too, so `sameTypeSource` cannot be what rejects this — only
		// the missing return annotation can.
		Assert.equals(0, violations('class Foo {} class C { function f(v:Foo) { return cast(v, Foo); } }').length);
	}

	public function testStructuralConstraintNotFlagged(): Void {
		// A structural constraint's own `)` must not stand in for the parameter list's: the second
		// constraint would otherwise read as the return type of a function that declares none.
		Assert.equals(
			0,
			violations(
				'class Foo {} class C { function f<A:{ function n():Void; }, B:Foo>() { return cast(mk(), Foo); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testStructuralConstraintWithReturnFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class Foo {} class C { function f<A:{ function n():Void; }, B:Foo>():Foo { return cast(mk(), Foo); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testCommentedParenInHeaderNotFlagged(): Void {
		// A `)` inside a header comment is not the parameter list either — the window refuses.
		Assert.equals(
			0,
			violations(
				'class Foo {} class C { function f /* ) */ <T:Foo>() { return cast(mk(), Foo); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testCommentInsideParameterListStillFlagged(): Void {
		// With a parameter present the test is purely structural, so a comment cannot suppress it.
		Assert.equals(
			1,
			violations(
				'class Foo {} class C { function f(a:Int /* c */):Foo { return cast(mk(), Foo); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testUntypedNestedBodyNotFlagged(): Void {
		// `UntypedBlockBody` is a function body too — the nested helper must own its own annotation.
		Assert.equals(
			0,
			violations(
				'class Foo {} class C { function f():Foo { inline function h() untyped { return cast(mk(), Foo); } return h(); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testDefaultValuedParamAheadOfSlotNotFlagged(): Void {
		// `a:Int = 1` projects as a plain required parameter yet Haxe skips it exactly like `?a`.
		Assert.equals(
			0, violations('class Foo {} class C { function g(a:Int = 1, b:Foo) {} function f(v:Dynamic) { g(1, cast(v, Foo)); } }').length
		);
	}

	public function testTrailingOptionalAfterSlotFlagged(): Void {
		// An optional BEHIND the slot cannot shift it, so the mapping still holds.
		Assert.equals(
			1, violations('class Foo {} class C { function g(a:Foo, ?b:Int) {} function f(v:Dynamic) { g(cast(v, Foo)); } }').length
		);
	}

	public function testTypeParameterConstraintNotFlagged(): Void {
		// `function f<T:Foo>()` projects the CONSTRAINT as the same `Named` node a return type
		// takes; only its position BEFORE the parameter list separates them.
		Assert.equals(
			0,
			violations('class Foo {} class C { function f<T:Foo>() { return cast(mk(), Foo); } function mk():Dynamic return null; }').length
		);
	}

	public function testTypeParameterConstraintWithParamsNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class Foo {} class C { function f<T:Foo>(p:Int) { return cast(mk(), Foo); } function mk():Dynamic return null; }').length
		);
	}

	public function testConstraintPlusReturnAnnotationFlagged(): Void {
		// Both a constraint and a return type: the annotation AFTER the parameter list is the one.
		Assert.equals(
			1,
			violations(
				'class Foo {} class C { function f<T:Foo>(p:Int):Foo { return cast(mk(), Foo); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testNestedInlineFunctionUsesItsOwnAnnotation(): Void {
		// `LocalInlineFnStmt` is in no `RefShape` function seam; without the body-child boundary its
		// unannotated return inherited the OUTER `:Foo` and fired.
		Assert.equals(
			0,
			violations(
				'class Foo {} class C { function f():Foo { inline function h() { return cast(mk(), Foo); } return h(); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testNestedNamedFunctionExpressionNotFlagged(): Void {
		// Same leak through `NamedFnExpr` — a `function h2() {…}` bound to a local.
		Assert.equals(
			0,
			violations(
				'class Foo {} class C { function f():Foo { final g = function h2() { return cast(mk(), Foo); }; return g(); } function mk():Dynamic return null; }'
			).length
		);
	}

	public function testRequiredSlotBehindOptionalNotFlagged(): Void {
		// The cast lands on the REQUIRED `b:Foo`, so a gate reading only the matched parameter lets it
		// through. Haxe nevertheless lets a call SKIP a non-trailing optional argument, so an optional
		// AHEAD of the slot destroys the positional mapping this whole arm rests on.
		Assert.equals(
			0, violations('class Foo {} class C { function g(?a:Int, b:Foo) {} function f(v:Dynamic) { g(1, cast(v, Foo)); } }').length
		);
	}

	public function testReturnInsideAnnotatedLambdaNotFlagged(): Void {
		// A lambda CLEARS the enclosing function — its own annotation is never consulted.
		Assert.equals(
			0,
			violations(
				'class Foo {} class C { function f(v:Dynamic):Foo { final g = function():Foo { return cast(v, Foo); }; return null; } }'
			).length
		);
	}

	public function testFieldAccessCalleeNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function f(o:Dynamic, v:Dynamic) { o.m(cast(v, Foo)); } }').length);
	}

	public function testOptionalParamSlotNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class C { function g(?a:Foo) {} function f(v:Dynamic) { g(cast(v, Foo)); } }').length);
	}

	public function testGenericCalleeNotFlagged(): Void {
		// `T` is a type PARAMETER, declared nowhere — the argument would DRIVE inference.
		Assert.equals(0, violations('class C { function pick<T>(v:T):T return v; function f(v:Dynamic) { pick(cast(v, T)); } }').length);
	}

	public function testDynamicTargetNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(v:Dynamic) { final a:Dynamic = cast(v, Dynamic); } }').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class Foo {} class C { function f(v:Dynamic) { final a:Foo = cast(v, Foo); } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-cast-type', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixRewritesToUncheckedCast(): Void {
		final out: String = applyFix('class Foo {} class C { function f(v:Dynamic) { final a:Foo = cast(v, Foo); } }');
		Assert.isTrue(out.indexOf('= cast v;') != -1, 'expected `= cast v;`, got: $out');
		Assert.isTrue(out.indexOf('cast(') == -1, 'checked cast should be gone, got: $out');
	}

	public function testFixRewritesCallArgument(): Void {
		final out: String = applyFix('class Foo {} class C { function g(a:Foo, b:Int) {} function f(v:Dynamic) { g(cast(v, Foo), 1); } }');
		Assert.isTrue(out.indexOf('g(cast v, 1)') != -1, 'expected `g(cast v, 1)`, got: $out');
	}

	public function testFixLeavesUnflaggedCastAlone(): Void {
		final src: String = 'class Foo {} class Bar {} class C { function f(v:Dynamic) { final a:Bar = cast(v, Foo); } }';
		final check: RedundantCastType = new RedundantCastType();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new RedundantCastType() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-cast-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-cast-type'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantCastType().run(
				[{ file: 'Bad.hx', source: 'class Bad { function f() { final a:Foo = cast(v, ' }], new HaxeQueryPlugin()
			)
				.length
		);
	}

	private function applyFix(src: String): String {
		final check: RedundantCastType = new RedundantCastType();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantCastType().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
