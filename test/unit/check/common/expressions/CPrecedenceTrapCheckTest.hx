package unit.check.common.expressions;

import anyparse.check.Severity;
import anyparse.check.common.expressions.CPrecedenceTrap;

/**
 * The `c-precedence-trap` check: a bare operand Haxe groups otherwise than C — a bitwise operand of a comparison, a looser
 * C bitwise operator under a tighter one, a `%` right of `*` / `/` — is flagged `Warning` and parenthesized the way the
 * parser already groups it. Shapes both readings agree on are left alone.
 */
class CPrecedenceTrapCheckTest extends Test {

	public function testBitwiseLeftOfComparisonFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('a & b != 0'));
		Assert.equals(1, vs.length);
		Assert.equals('c-precedence-trap', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testBitwiseRightOfComparisonFlagged(): Void {
		Assert.equals(1, violations(wrap('0 == a | b')).length);
	}

	/** Haxe reads `a | b & c` as `(a | b) & c`, C as `a | (b & c)`. */
	public function testLooserBitwiseUnderTighterFlagged(): Void {
		Assert.equals(1, violations(wrap('a | b & c')).length);
		Assert.equals(1, violations(wrap('a ^ b & c')).length);
		Assert.equals(1, violations(wrap('a | b ^ c')).length);
	}

	/** Haxe reads `a * b % c` as `a * (b % c)`, C as `(a * b) % c`. */
	public function testModRightOfMulFlagged(): Void {
		Assert.equals(1, violations(wrap('a * b % c')).length);
		Assert.equals(1, violations(wrap('a / b % c')).length);
	}

	/** Both readings group these alike: a tighter C operator first, one operator twice, `%` on the left, a written pair. */
	public function testAgreeingGroupingsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('a & b | c')).length);
		Assert.equals(0, violations(wrap('a & b ^ c')).length);
		Assert.equals(0, violations(wrap('a & b & c')).length);
		Assert.equals(0, violations(wrap('a % b * c')).length);
		Assert.equals(0, violations(wrap('(a & b) != 0')).length);
		Assert.equals(0, violations(wrap('a + b != 0')).length);
	}

	public function testFixParenthesizesTheOperand(): Void {
		Assert.equals(wrap('(a & b) != 0'), applyFix(wrap('a & b != 0')));
		Assert.equals(wrap('a * (b % c)'), applyFix(wrap('a * b % c')));
	}

	/** A bitwise operand on the RIGHT of a comparison is wrapped in place. */
	public function testFixWrapsRightOperand(): Void {
		Assert.equals(wrap('a < (b & c)'), applyFix(wrap('a < b & c')));
	}

	/** An interpolation block's expression is an ordinary expression: its operand is found and wrapped inside the `${…}`. */
	public function testFixInsideInterpolation(): Void {
		Assert.equals(wrap("'${(a & b) != 0}'"), applyFix(wrap("'${a & b != 0}'")));
	}

	/** Two nested findings: one pass wraps the outer operand only, so no two edits overlap. */
	@:pin('control')
	@:killer('M-CPREC-NESTED-EDITS-OVERLAP')
	public function testFixWrapsOutermostOfNestedFindings(): Void {
		Assert.equals(2, violations(wrap('a | b & c != 0')).length);
		Assert.equals(wrap('(a | b & c) != 0'), applyFix(wrap('a | b & c != 0')));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('c-precedence-trap'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f(a:Int, b:Int, c:Int):Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new CPrecedenceTrap(), src);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new CPrecedenceTrap(), src);
	}

}
