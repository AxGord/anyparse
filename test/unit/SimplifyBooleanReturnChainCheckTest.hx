package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.SimplifyBooleanReturnChain;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `simplify-boolean-return-chain` check: a contiguous run of two-or-more
 * `if (cond) return true/false;` guards closed by a final `return true/false;`
 * reduces to a single flat boolean `return` (`||` / `!… &&` by De Morgan). The
 * conditions are kept verbatim and are sound to join because each is an `if`
 * condition (non-null `Bool`). Value-returning guards, single guards,
 * non-contiguous runs, and degenerate chains that would drop a condition's
 * evaluation are left alone.
 */
class SimplifyBooleanReturnChainCheckTest extends Test {

	public function testAllTrueToOr(): Void {
		Assert.equals('return a || b;', reduce('{ if (a) return true; if (b) return true; return false; }'));
	}

	public function testAllFalseToAndNot(): Void {
		Assert.equals('return !a && !b;', reduce('{ if (a) return false; if (b) return false; return true; }'));
	}

	public function testMixedToOrNot(): Void {
		Assert.equals('return a || !b;', reduce('{ if (a) return true; if (b) return false; return true; }'));
	}

	public function testThreeGuards(): Void {
		Assert.equals('return a || b || c;', reduce('{ if (a) return true; if (b) return true; if (c) return true; return false; }'));
	}

	public function testComparisonConditions(): Void {
		Assert.equals('return x > 0 || x < 0;', reduce('{ if (x > 0) return true; if (x < 0) return true; return false; }'));
	}

	public function testCallConditions(): Void {
		// The case that got stuck as `g() ? true : h()` through the ternary path.
		Assert.equals('return g() || h();', reduce('{ if (g()) return true; if (h()) return true; return false; }'));
	}

	public function testValueGuardsNotFlagged(): Void {
		Assert.equals(0, violations('{ if (a) return 1; if (b) return 2; return 3; }').length);
	}

	public function testSingleGuardNotFlagged(): Void {
		// One guard is the prefer-ternary / simplify domain, not this check.
		Assert.equals(0, violations('{ if (a) return true; return false; }').length);
	}

	public function testNonContiguousNotFlagged(): Void {
		Assert.equals(0, violations('{ if (a) return true; b = !b; if (c) return true; return false; }').length);
	}

	public function testDegenerateAbsorbNotFlagged(): Void {
		// `b` would be dropped (`b || true` -> true): refuse, never drop a condition's evaluation.
		Assert.equals(0, violations('{ if (a) return true; if (b) return true; return true; }').length);
	}

	public function testGuardWithElseNotFlagged(): Void {
		Assert.equals(0, violations('{ if (a) return true; else return false; if (b) return true; return false; }').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('{ if (a) return true; if (b) return true; return false; }');
		Assert.equals(1, vs.length);
		Assert.equals('simplify-boolean-return-chain', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new SimplifyBooleanReturnChain().run([{ file: 'Bad.hx', source: 'class Bad { function f() { ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('simplify-boolean-return-chain'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('simplify-boolean-return-chain'));
	}

	/** The `&& false` absorb arm: `b` would be dropped (`!b && false` -> false): refuse. */
	public function testDegenerateAbsorbFalseArmNotFlagged(): Void {
		Assert.equals(0, violations('{ if (a) return false; if (b) return false; return false; }').length);
	}

	public function testBracedGuardsToOr(): Void {
		Assert.equals('return a || b;', reduce('{ if (a) { return true; } if (b) { return true; } return false; }'));
	}

	public function testMixedBracedAndBareToOr(): Void {
		Assert.equals('return a || b;', reduce('{ if (a) return true; if (b) { return true; } return false; }'));
	}

	public function testBracedThreeGuardsToOr(): Void {
		Assert.equals(
			'return a || b || c;', reduce('{ if (a) { return true; } if (b) { return true; } if (c) { return true; } return false; }')
		);
	}

	public function testBracedGuardWithExtraStatementNotFlagged(): Void {
		// The first block carries another statement, so flattening it would drop `x++`:
		// it is not a guard, leaving a single guard below the 2-guard threshold.
		Assert.equals(0, violations('{ if (a) { x++; return true; } if (b) { return true; } return false; }').length);
	}

	private function violations(body: String): Array<Violation> {
		final src: String = 'class C { static function f(a: Bool, b: Bool, c: Bool, x: Int): Dynamic ${body} }';
		return new SimplifyBooleanReturnChain().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The rewrite text the fix emits for the first chain in `body` (empty if none). */
	private function reduce(body: String): String {
		final src: String = 'class C { static function f(a: Bool, b: Bool, c: Bool, x: Int): Dynamic ${body} }';
		final check: SimplifyBooleanReturnChain = new SimplifyBooleanReturnChain();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
	}

}
