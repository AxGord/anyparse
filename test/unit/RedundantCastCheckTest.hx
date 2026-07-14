package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantCast;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-cast` check: a `cast(x, T)` / `(x : T)` whose target type equals
 * the operand's declared type is a no-op. The untyped `cast x`, a type mismatch, a
 * non-identifier operand, or an operand with no recovered type are not flagged.
 * `fix` unwraps a flagged cast to its operand.
 */
class RedundantCastCheckTest extends Test {

	public function testTypedCastFlagged(): Void {
		Assert.equals(1, violations('class C { function f(x:Int) { final a:Int = cast(x, Int); } }').length);
	}

	public function testCheckTypeFlagged(): Void {
		Assert.equals(1, violations('class C { function f(x:Int) { final a:Int = (x : Int); } }').length);
	}

	public function testMismatchNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(x:Int) { final a:String = cast(x, String); } }').length);
	}

	public function testUntypedCastNotFlagged(): Void {
		// `cast x` carries no target type — never a redundant-cast candidate.
		Assert.equals(0, violations('class C { function f(x:Int) { final a:Int = cast x; } }').length);
	}

	public function testNonIdentOperandNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { final a:Int = cast(g(), Int); } function g():Int return 0; }').length);
	}

	public function testUnresolvedOperandNotFlagged(): Void {
		// `v` is unannotated, so its type is not recovered — no comparison possible.
		Assert.equals(
			0, violations('class C { function f() { var v = g(); final a:Int = cast(v, Int); } function g():Int return 0; }').length
		);
	}

	public function testFixUnwrapsTypedCast(): Void {
		final out: String = applyFix('class C { function f(x:Int) { final a:Int = cast(x, Int); } }');
		Assert.isTrue(out.indexOf('= x;') != -1, 'expected `= x;`, got: $out');
		Assert.isTrue(out.indexOf('cast(') == -1, 'cast should be gone, got: $out');
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(x:Int) { final a:Int = cast(x, Int); } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-cast', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new RedundantCast().run([{ file: 'Bad.hx', source: 'class Bad { function f() { cast(' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-cast'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-cast'));
	}

	public function testNestedInnerCastResolvesOwnTarget(): Void {
		// The inner `cast(x, String)` must resolve to String (a mismatch, not flagged), NOT
		// inherit the outer cast's `Int` target — locks the `castTargetWithin` span lookup.
		Assert.equals(0, violations('class C { function f(x:Int) { final a:Int = cast(cast(x, String), Int); } }').length);
	}

	public function testFixUnwrapsCheckType(): Void {
		final out: String = applyFix('class C { function f(x:Int) { final a:Int = (x : Int); } }');
		Assert.isTrue(out.indexOf('= x;') != -1, 'expected `= x;`, got: $out');
		Assert.isTrue(out.indexOf('(x :') == -1, 'check-type should be gone, got: $out');
	}

	public function testParametricMatchFlagged(): Void {
		Assert.equals(1, violations('class C { function f(a:Array<Int>) { final x:Array<Int> = cast(a, Array<Int>); } }').length);
	}

	public function testParametricMismatchNotFlagged(): Void {
		// `Array<String>` vs `Array<Int>` differ only in type params — source comparison catches it
		// where a package-stripped simple-name match (`Array` == `Array`) would falsely flag.
		Assert.equals(0, violations('class C { function f(a:Array<String>) { final x:Array<Int> = cast(a, Array<Int>); } }').length);
	}

	public function testCrossPackageNotFlagged(): Void {
		// Same simple name, different package — source comparison keeps them distinct.
		Assert.equals(0, violations('class C { function f(e:haxe.io.Eof) { final x:haxe.io.Eof = cast(e, sys.io.Eof); } }').length);
	}

	public function testStringConstTypeParamNotFlagged(): Void {
		// `Foo<"a b">` vs `Foo<"ab">` differ only by whitespace INSIDE a string-literal const type
		// param, where whitespace IS significant — they must not be equated (verbatim comparison).
		Assert.equals(0, violations('class C { function f(a:Foo<"a b">) { final x:Foo<"ab"> = cast(a, Foo<"ab">); } }').length);
	}

	public function testStringConstTypeParamMatchFlagged(): Void {
		Assert.equals(1, violations('class C { function f(a:Foo<"a b">) { final x:Foo<"a b"> = cast(a, Foo<"a b">); } }').length);
	}

	public function testImportResolvedBareVsQualifiedFlagged(): Void {
		// `e` is `Eof` (imported `haxe.io.Eof`); the cast target is the qualified spelling — same type.
		Assert.equals(
			1, violations('import haxe.io.Eof; class C { function f(e:Eof) { final x:haxe.io.Eof = cast(e, haxe.io.Eof); } }').length
		);
	}

	public function testImportResolvedQualifiedVsBareFlagged(): Void {
		Assert.equals(1, violations('import haxe.io.Eof; class C { function f(e:haxe.io.Eof) { final x:Eof = cast(e, Eof); } }').length);
	}

	public function testImportResolvedCrossPackageNotFlagged(): Void {
		// `e` resolves to `haxe.io.Eof`; the cast `sys.io.Eof` is a different package — distinct.
		Assert.equals(0, violations('import haxe.io.Eof; class C { function f(e:Eof) { final x:Eof = cast(e, sys.io.Eof); } }').length);
	}

	public function testNoImportBareVsQualifiedNotFlagged(): Void {
		// No import for `Eof`, so the bare name can't be proven equal to qualified `haxe.io.Eof` — safe miss.
		Assert.equals(0, violations('class C { function f(e:haxe.io.Eof) { final x:Eof = cast(e, Eof); } }').length);
	}

	public function testFixUnwrapsImportResolved(): Void {
		final out: String = applyFix('import haxe.io.Eof; class C { function f(e:Eof) { final x:haxe.io.Eof = cast(e, haxe.io.Eof); } }');
		Assert.isTrue(out.indexOf('= e;') != -1, 'expected `= e;`, got: $out');
		Assert.isTrue(out.indexOf('cast(') == -1, 'cast should be gone, got: $out');
	}

	public function testTypeParamShadowNotFlagged(): Void {
		// `x` is the method type parameter `T`, NOT the imported `a.b.T`; the cast is a real
		// coercion. The import-resolution must exclude type-param names to avoid a destructive FP.
		Assert.equals(0, violations('import a.b.T; class C { function f<T>(x:T) { var a = cast(x, a.b.T); } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantCast().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: RedundantCast = new RedundantCast();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

}
