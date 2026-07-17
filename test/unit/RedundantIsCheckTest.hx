package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantIsCheck;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-is-check` check: an `is` type-check `x is T` that is provably ALWAYS
 * TRUE — `x` is a plain identifier of declared type `T` AND provably non-null. Only the
 * always-true direction is detected (always-false needs a class hierarchy anyparse does
 * not model). A nullable operand (no `@:nullSafety`, `Null<…>`, optional param), a
 * different checked type, or a non-identifier operand keep the conservative default.
 */
class RedundantIsCheckTest extends Test {

	public function testValueTypeSameTypeFlagged(): Void {
		// `Int` is non-null on static targets regardless of null-safety; `i is Int` is constant.
		Assert.equals(1, violations('class C { function f(i:Int) { var b = i is Int; } }').length);
	}

	public function testNullSafeNominalSameTypeFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(s:String) { var b = s is String; } }').length);
	}

	public function testNonNullSafeNominalNotFlagged(): Void {
		// No null-safety: `s` may be null, and `null is String` is false — not constant.
		Assert.equals(0, violations('class C { function f(s:String) { var b = s is String; } }').length);
	}

	public function testDifferentTypeNotFlagged(): Void {
		// `i:Int is String` — different types; always-false is intentionally not detected.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(i:Int) { var b = i is String; } }').length);
	}

	public function testNullableWrapperNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(n:Null<String>) { var b = n is String; } }').length);
	}

	public function testOptionalParamNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(?s:String) { var b = s is String; } }').length);
	}

	public function testNonIdentifierOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations('@:nullSafety(Strict) class C { function f() { var b = make() is String; } function make():String return ""; }').length
		);
	}

	public function testQualifiedTypeReconciledFlagged(): Void {
		// `e:Eof` vs checked `haxe.io.Eof` reconcile via importMap → same FQN → flagged.
		Assert.equals(
			1, violations('import haxe.io.Eof;\n@:nullSafety(Strict) class C { function f(e:Eof) { var b = e is haxe.io.Eof; } }').length
		);
	}

	public function testQualifiedDifferentPackageNotFlagged(): Void {
		// `e:Eof` (haxe.io.Eof) vs `sys.io.Eof` — distinct FQNs, not flagged.
		Assert.equals(
			0, violations('import haxe.io.Eof;\n@:nullSafety(Strict) class C { function f(e:Eof) { var b = e is sys.io.Eof; } }').length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(i:Int) { var b = i is Int; } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-is-check', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: RedundantIsCheck = new RedundantIsCheck();
		final src: String = 'class C { function f(i:Int) { var b = i is Int; } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testDefaultNullParamFlaggedButNotFixed(): Void {
		// KNOWN run FALSE POSITIVE, same root cause as `unnecessary-null-check`: a
		// `s:T = null` default-null parameter is nullable per Haxe null-safety, but the
		// declared-type proof treats it as non-null and flags `s is T`. Unwrapping that
		// `is`-check would introduce an NPE (`null is T` is false), so `fix` stays a no-op.
		final check: RedundantIsCheck = new RedundantIsCheck();
		final src: String = '@:nullSafety(Strict) class C { function f(s:String = null) { if (s is String) trace(s.length); } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantIsCheck().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var b = x is ' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-is-check'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-is-check'));
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantIsCheck().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
