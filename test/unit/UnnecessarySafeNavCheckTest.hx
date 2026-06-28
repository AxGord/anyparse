package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnnecessarySafeNav;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `unnecessary-safe-nav` check: a null-safe access (`a?.b`) whose receiver is
 * provably non-null — a value type (`Int` / …) or a non-`Null<…>` nominal type while
 * the enclosing type is `@:nullSafety`. An optional parameter, a `Null<…>` / `Dynamic`
 * receiver, a non-null-safe class, or a non-identifier receiver (a chained `a.b?.c` /
 * `a()?.c`) keep the conservative default and are not flagged. The rewrite drops the
 * `?` (`?.` becomes `.`).
 */
class UnnecessarySafeNavCheckTest extends Test {

	public function testValueTypeReceiverFlagged(): Void {
		// `Int` is non-null on static targets regardless of null-safety.
		Assert.equals(1, violations('class C { function f(i:Int) { var s = i?.foo; } }').length);
	}

	public function testNullSafeNominalFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(s:String) { var n = s?.length; } }').length);
	}

	public function testMethodCallReceiverFlagged(): Void {
		// `s?.charAt(0)` parses as Call(SafeFieldAccess) — the SafeFieldAccess receiver is still `s`.
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(s:String) { s?.charAt(0); } }').length);
	}

	public function testNonNullSafeNominalNotFlagged(): Void {
		// No null-safety meta: a class-typed `s` may be null at runtime.
		Assert.equals(0, violations('class C { function f(s:String) { var n = s?.length; } }').length);
	}

	public function testNullSafetyOffNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Off) class C { function f(s:String) { var n = s?.length; } }').length);
	}

	public function testNullableWrapperNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(n:Null<String>) { var x = n?.length; } }').length);
	}

	public function testDynamicNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(d:Dynamic) { var x = d?.foo; } }').length);
	}

	public function testOptionalParamNotFlagged(): Void {
		// `?s:String` is nullable despite the nominal annotation.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(?s:String) { var x = s?.length; } }').length);
	}

	public function testChainedReceiverNotFlagged(): Void {
		// Receiver `s.toString()` is a call, not a plain identifier — unresolved, conservative.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(s:String) { var x = s.toString()?.length; } }').length);
	}

	public function testUnannotatedLocalNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'@:nullSafety(Strict) class C { function f() { var v = make(); var x = v?.length; } function make():Null<String> return null; }'
			).length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(i:Int) { var s = i?.foo; } }');
		Assert.equals(1, vs.length);
		Assert.equals('unnecessary-safe-nav', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixRewritesQuestionDot(): Void {
		final check: UnnecessarySafeNav = new UnnecessarySafeNav();
		final src: String = 'class C { function f(i:Int) { var s = i?.foo; } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		Assert.equals('.', edits[0].text);
		Assert.equals('?.', src.substring(edits[0].span.from, edits[0].span.to));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new UnnecessarySafeNav().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var x = a?.' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unnecessary-safe-nav'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unnecessary-safe-nav'));
	}

	private function violations(src: String): Array<Violation> {
		return new UnnecessarySafeNav().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
