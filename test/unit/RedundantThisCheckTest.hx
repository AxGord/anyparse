package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantThis;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-this` check: a `this.field` access reduces to bare `field`
 * when no local / parameter / loop-var / local-function in the enclosing member
 * shadows the name. Shadowed accesses (the `this.x = x` constructor pattern) and
 * compile-time abstracts (where `this` is the underlying value) are left alone.
 */
class RedundantThisCheckTest extends Test {

	public function testRedundantThisFlagged(): Void {
		Assert.equals(1, violations('class C { var f:Int; function m():Int { return this.f; } }').length);
	}

	public function testFixDropsThis(): Void {
		final out: String = applyFix('class C { var f:Int; function m():Int { return this.f; } }');
		Assert.isTrue(out.indexOf('return f;') != -1, 'expected `return f;`, got: $out');
		Assert.isTrue(out.indexOf('this.f') == -1, 'this. should be gone, got: $out');
	}

	public function testConstructorShadowNotFlagged(): Void {
		// `this.x = x`: the parameter shadows the field, so `this.` is required.
		Assert.equals(0, violations('class C { var x:Int; public function new(x:Int) { this.x = x; } }').length);
	}

	public function testLocalVarShadowNotFlagged(): Void {
		Assert.equals(0, violations('class C { var f:Int; function m() { var f = 1; trace(this.f); } }').length);
	}

	public function testLocalFunctionShadowNotFlagged(): Void {
		Assert.equals(0, violations('class C { var helper:Int; function m() { function helper() {}; trace(this.helper); } }').length);
	}

	public function testMethodCallThisFlagged(): Void {
		Assert.equals(1, violations('class C { function go() {} function m() { this.go(); } }').length);
		final out: String = applyFix('class C { function go() {} function m() { this.go(); } }');
		Assert.isTrue(out.indexOf('go();') != -1 && out.indexOf('this.go') == -1, 'got: $out');
	}

	public function testChainedThisInnerFlagged(): Void {
		// Only the inner `this.a` is a this-access; the outer `.b` is not.
		final out: String = applyFix('class C { var a:Dynamic; function m() { return this.a.b; } }');
		Assert.isTrue(out.indexOf('return a.b;') != -1, 'got: $out');
	}

	public function testAbstractThisNotMatched(): Void {
		// In `abstract A(T)` the `this.x` carries no IdentExpr-this receiver and
		// `this.` is mandatory — never flagged.
		Assert.equals(
			0,
			new RedundantThis().run([{ file: 'A.hx', source: 'abstract A(Int) { function f() return this.x; }' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { var f:Int; function m():Int { return this.f; } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-this', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new RedundantThis().run([{ file: 'Bad.hx', source: 'class Bad { function f() { ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-this'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-this'));
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantThis().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: RedundantThis = new RedundantThis();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

}
