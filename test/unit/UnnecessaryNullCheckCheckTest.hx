package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnnecessaryNullCheck;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `unnecessary-null-check` check: a comparison against `null` whose operand
 * is provably non-null — a value type (`Int` / `Float` / `Bool` / `UInt`) or a
 * non-`Null<…>` nominal type while the enclosing type is `@:nullSafety`. An
 * optional parameter, a `Null<…>` / `Dynamic` operand, a non-null-safe class, or
 * a non-identifier operand keep the conservative default and are not flagged.
 */
class UnnecessaryNullCheckCheckTest extends Test {

	public function testValueTypeParamFlagged(): Void {
		// `Int` is non-null on static targets regardless of null-safety.
		Assert.equals(1, violations('class C { function f(x:Int) { if (x != null) trace(x); } }').length);
	}

	public function testValueTypeLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { final i:Int = 0; if (i != null) trace(i); } }').length);
	}

	public function testEitherOperandOrder(): Void {
		Assert.equals(1, violations('class C { function f(x:Int) { if (null == x) trace(x); } }').length);
	}

	public function testNullSafeNominalFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(s:String) { if (s != null) trace(s); } }').length);
	}

	public function testNonNullSafeNominalNotFlagged(): Void {
		// No null-safety meta: a class-typed `s` may be null at runtime.
		Assert.equals(0, violations('class C { function f(s:String) { if (s != null) trace(s); } }').length);
	}

	public function testNullSafetyOffNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Off) class C { function f(s:String) { if (s != null) trace(s); } }').length);
	}

	public function testNullableWrapperNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(n:Null<String>) { if (n != null) trace(n); } }').length);
	}

	public function testDynamicNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(d:Dynamic) { if (d != null) trace(d); } }').length);
	}

	public function testOptionalParamNotFlagged(): Void {
		// `?x:Int` is nullable despite the nominal `Int` annotation.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(?x:Int) { if (x != null) trace(x); } }').length);
	}

	public function testDefaultedParamFlagged(): Void {
		// `x:Int = 0` is a required (non-null) parameter — the null check is redundant.
		Assert.equals(1, violations('class C { function f(x:Int = 0) { if (x != null) trace(x); } }').length);
	}

	public function testCallOperandNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f() { if (foo() != null) trace(1); } function foo():Null<String> return null; }').length
		);
	}

	public function testUnannotatedLocalNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'@:nullSafety(Strict) class C { function f() { var v = make(); if (v != null) trace(v); } function make():Null<String> return null; }'
			).length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(x:Int) { if (x != null) trace(x); } }');
		Assert.equals(1, vs.length);
		Assert.equals('unnecessary-null-check', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: UnnecessaryNullCheck = new UnnecessaryNullCheck();
		final src: String = 'class C { function f(x:Int) { if (x != null) trace(x); } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testDefaultNullParamFlaggedButNotFixed(): Void {
		// KNOWN run FALSE POSITIVE: a `p:T = null` default-null parameter is nullable per
		// Haxe null-safety ("an argument with a default value of null is nullable"), but the
		// declared-type proof treats every defaulted param as non-null and flags it. Because
		// that proof is unsound here, `fix` stays a no-op — auto-deleting the guard would
		// introduce an NPE. Only the flow-proven `dead-null-guard` autofixes. When the run
		// proof is tightened to exempt default-null params, wire the rewrite via
		// `CheckScan.simplifyNullComparisonFixes` (already built + tested by `dead-null-guard`).
		final check: UnnecessaryNullCheck = new UnnecessaryNullCheck();
		final src: String = '@:nullSafety(Strict) class C { function f(p:String = null) { if (p != null) trace(p); } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new UnnecessaryNullCheck().run([{ file: 'Bad.hx', source: 'class Bad { function f() { if (x != ' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unnecessary-null-check'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unnecessary-null-check'));
	}

	private function violations(src: String): Array<Violation> {
		return new UnnecessaryNullCheck().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
