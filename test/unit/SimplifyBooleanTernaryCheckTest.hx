package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.SimplifyBooleanTernary;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.check.Severity;

/**
 * The `simplify-boolean-ternary` check: a ternary with a boolean-literal branch
 * is reduced to a boolean expression, with any negation pushed inward by De
 * Morgan. The four mixed forms and the two pure-literal forms are asserted on the
 * exact rewrite text; a real-valued ternary and a same-literal ternary are left
 * alone.
 */
class SimplifyBooleanTernaryCheckTest extends Test {

	public function testCondXFalseToAnd(): Void {
		Assert.equals('p && x > 0', simplifyOf('return p ? x > 0 : false;'));
	}

	public function testCondTrueXToOr(): Void {
		Assert.equals('p || x > 0', simplifyOf('return p ? true : x > 0;'));
	}

	public function testCondXTrueToNotOr(): Void {
		Assert.equals('!p || x > 0', simplifyOf('return p ? x > 0 : true;'));
	}

	public function testCondFalseXToNotAnd(): Void {
		Assert.equals('!p && x > 0', simplifyOf('return p ? false : x > 0;'));
	}

	public function testDeMorganOrCondition(): Void {
		// cond ? false : x  with a `||` of comparisons -> negation pushed all the way in.
		Assert.equals('a != 0 && b != 0 && x > 0', simplifyOf('return a == 0 || b == 0 ? false : x > 0;'));
	}

	public function testDeMorganAndCondition(): Void {
		// !(a && b) -> !a || !b ; wrapped because `||` binds looser than the joining `&&`.
		Assert.equals('(!a || !b) && x > 0', simplifyOf('return a && b ? false : x > 0;'));
	}

	public function testPureTrueFalseToCond(): Void {
		Assert.equals('a == b', simplifyOf('return a == b ? true : false;'));
	}

	public function testPureFalseTrueToNotCond(): Void {
		Assert.equals('a != b', simplifyOf('return a == b ? false : true;'));
	}

	public function testCompoundCondParenthesised(): Void {
		// cond ? x : false -> cond && x ; a `||` cond is wrapped to keep precedence.
		Assert.equals('(a > 0 || b > 0) && x > 0', simplifyOf('return a > 0 || b > 0 ? x > 0 : false;'));
	}

	public function testNotConditionStripped(): Void {
		// cond ? false : x with cond = !p -> !!p && x -> p && x.
		Assert.equals('p && x > 0', simplifyOf('return !p ? false : x > 0;'));
	}

	public function testRealValuedTernaryNotFlagged(): Void {
		Assert.equals(0, violations('return c ? 1 : 2;').length);
	}

	public function testSameLiteralNotFlagged(): Void {
		// cond ? true : true would drop cond's evaluation — left alone.
		Assert.equals(0, violations('return c ? true : true;').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('return p ? x > 0 : false;');
		Assert.equals(1, vs.length);
		Assert.equals('simplify-boolean-ternary', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new SimplifyBooleanTernary().run([{ file: 'Bad.hx', source: 'class Bad { function f() { ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('simplify-boolean-ternary'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('simplify-boolean-ternary'));
	}

	private function violations(body: String): Array<Violation> {
		final src: String = 'class C { static function f(a: Int, b: Int, c: Bool, p: Bool, x: Int): Dynamic ${body} }';
		return new SimplifyBooleanTernary().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The rewrite text the fix emits for the first ternary in `body` (empty if none). */
	private function simplifyOf(body: String): String {
		final src: String = 'class C { static function f(a: Int, b: Int, c: Bool, p: Bool, x: Int): Dynamic ${body} }';
		final check: SimplifyBooleanTernary = new SimplifyBooleanTernary();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
	}

	/** A null-narrowing-guarded condition is left alone — flattening would break the narrowing. */
	public function testNullNarrowingGuardNotSimplified(): Void {
		Assert.equals("", simplifyOf("return c != null && c.foo() != null ? true : x > 0;"));
	}

	/** A bare null-check (no access of the same ident) is still simplified. */
	public function testBareNullCheckStillSimplified(): Void {
		Assert.equals("c != null || x > 0", simplifyOf("return c != null ? true : x > 0;"));
	}

	/** Index-access reuse guards the ternary form too. */
	public function testIndexAccessGuardNotSimplified(): Void {
		Assert.equals("", simplifyOf("return c != null && c[0] > 0 ? true : x > 0;"));
	}

	/** A `null` branch makes the ternary `Null<Bool>`, not a boolean expression — left alone. */
	public function testTrueNullNotSimplified(): Void {
		Assert.equals('', simplifyOf('return p ? true : null;'));
		Assert.equals(0, violations('return p ? true : null;').length);
	}

	/** Same for a `false` / `null` ternary — the `null` branch is not provably Bool. */
	public function testFalseNullNotSimplified(): Void {
		Assert.equals('', simplifyOf('return p ? false : null;'));
	}

	/** A bare-identifier branch may be a `Null<Bool>` local — not provably Bool, so left alone. */
	public function testBareIdentBranchNotSimplified(): Void {
		Assert.equals('', simplifyOf('return p ? true : c;'));
		Assert.equals(0, violations('return p ? true : c;').length);
	}

}
