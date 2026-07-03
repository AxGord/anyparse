package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UncheckedNullable;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `unchecked-nullable` check: the result of `Std.parseInt` / `Std.parseFloat`
 * (a `Null<Int>` / `Null<Float>`) used directly as a number — a numeric-operator
 * operand or an array index — is flagged `Warning`. Null-tolerant `==` / `!=`,
 * string concatenation, and the safe usages (bare binding, argument passing) are
 * not. Report-only — `fix` yields no edits.
 */
class UncheckedNullableTest extends Test {

	public function testArithmeticFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(s:String) { var a = Std.parseInt(s) + 1; } }');
		Assert.equals(1, vs.length);
		Assert.equals('unchecked-nullable', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('result of Std.parseInt can be null; it is used as a number here with no null check', vs[0].message);
	}

	public function testSubtractionFlagged(): Void {
		Assert.equals(1, violations('class C { function f(s:String) { var a = Std.parseInt(s) - 1; } }').length);
	}

	public function testRelationalFlagged(): Void {
		Assert.equals(1, violations('class C { function f(s:String) { var a = Std.parseInt(s) < 3; } }').length);
	}

	public function testBitwiseFlagged(): Void {
		Assert.equals(1, violations('class C { function f(s:String) { var a = Std.parseInt(s) & 255; } }').length);
	}

	public function testUnaryNegFlagged(): Void {
		Assert.equals(1, violations('class C { function f(s:String) { var a = -Std.parseInt(s); } }').length);
	}

	public function testArrayIndexFlagged(): Void {
		Assert.equals(1, violations('class C { function f(s:String, arr:Array<Int>) { var a = arr[Std.parseInt(s)]; } }').length);
	}

	public function testParseFloatFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(s:String) { var a = Std.parseFloat(s) * 2.0; } }');
		Assert.equals(1, vs.length);
		Assert.equals('result of Std.parseFloat can be null; it is used as a number here with no null check', vs[0].message);
	}

	public function testTwoOperandsBothFlagged(): Void {
		Assert.equals(2, violations('class C { function f(s:String, t:String) { var a = Std.parseInt(s) + Std.parseInt(t); } }').length);
	}

	public function testEqualityNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(s:String) { var a = Std.parseInt(s) == 3; } }').length);
	}

	public function testNotEqualityNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(s:String) { var a = Std.parseInt(s) != 3; } }').length);
	}

	public function testStringConcatDoubleQuoteNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(s:String) { var a = Std.parseInt(s) + "x"; } }').length);
	}

	public function testStringConcatSingleQuoteNotFlagged(): Void {
		Assert.equals(0, violations("class C { function f(s:String) { var a = Std.parseInt(s) + 'x'; } }").length);
	}

	public function testStringConcatLeftNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(s:String) { var a = "n=" + Std.parseInt(s); } }').length);
	}

	public function testBareBindingNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(s:String) { var n = Std.parseInt(s); } }').length);
	}

	public function testArgumentNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(s:String) { trace(Std.parseInt(s)); } }').length);
	}

	public function testNonStdReceiverNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(o:Dynamic) { var a = o.parseInt("1") + 1; } }').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C { function f(s:String) { var a = Std.parseInt(s) + 1; } }';
		final check: UncheckedNullable = new UncheckedNullable();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unchecked-nullable'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unchecked-nullable'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new UncheckedNullable().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
