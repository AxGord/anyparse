package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferSwitch;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `prefer-switch` check: an `if` / `else if` chain testing one expression
 * against literal values is flagged `Info`. A chain over different
 * discriminants, a non-equality or `!=` condition, a non-literal or interpolated
 * operand, a call-bearing discriminant, or a lone `if` is not. Report-only —
 * `fix` yields no edits.
 */
class PreferSwitchCheckTest extends Test {

	public function testStringChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap("if (x == 'a') a(); else if (x == 'b') b(); else c();"));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-switch', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testIntChainFlagged(): Void {
		Assert.equals(1, violations(wrap('if (n == 1) a(); else if (n == 2) b();')).length);
	}

	public function testFieldAccessDiscriminantFlagged(): Void {
		Assert.equals(1, violations(wrap("if (child.nodeName == 'f') a(); else if (child.nodeName == 'g') b();")).length);
	}

	public function testLiteralLeftOperandFlagged(): Void {
		Assert.equals(1, violations(wrap('if (1 == n) a(); else if (2 == n) b();')).length);
	}

	public function testThreeRungChainSingleFinding(): Void {
		Assert.equals(1, violations(wrap("if (x == 'a') a(); else if (x == 'b') b(); else if (x == 'c') c();")).length);
	}

	public function testDifferentDiscriminantsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a(); else if (y == 2) b();')).length);
	}

	public function testNonEqualityNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a(); else if (x > 2) b();')).length);
	}

	public function testNonLiteralOperandNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == y) a(); else if (x == z) b();')).length);
	}

	public function testInterpolatedStringNotFlagged(): Void {
		Assert.equals(0, violations(wrap("if (x == '$y') a(); else if (x == '$z') b();")).length);
	}

	public function testCallDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (get() == 1) a(); else if (get() == 2) b();')).length);
	}

	public function testLoneIfNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a();')).length);
	}

	public function testSingleIfElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a(); else b();')).length);
	}

	public function testNotEqChainNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x != 1) a(); else if (x != 2) b();')).length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = wrap("if (x == 'a') a(); else if (x == 'b') b();");
		final check: PreferSwitch = new PreferSwitch();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-switch'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-switch'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferSwitch().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
