package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.SimplifyBooleanReturnChain;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

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

	/**
	 * THE FLAGSHIP REGRESSION: a `String`-typed ordered guard condition keeps its `!( … )` wrap.
	 * Before this rule threaded a type resolver the chain reducer flipped ordered comparisons
	 * UNCONDITIONALLY, so this chain reduced to `s >= t && !b` — and with `s = null` the guard
	 * chain returns `true` while that rewrite returns `false` (measured on `--interp` and `js`,
	 * Haxe 4.3.7). Haxe has no non-nullable string type, so a `String` declaration proves
	 * nothing about null and the flip is never licensed.
	 */
	public function testStringOrderedGuardKeepsWrap(): Void {
		Assert.equals('return !(s < t) && !b;', reduce('{ if (s < t) return false; if (b) return false; return true; }'));
	}

	/**
	 * A `Float` operand is refused for the other reason the flip can break: `!(y < 0.5)` is
	 * `true` for a NaN `y` where `y >= 0.5` is `false`. The unconditional mode got this wrong
	 * too — the `String` repro is just the one a reviewer reproduced first.
	 */
	public function testFloatOrderedGuardKeepsWrap(): Void {
		Assert.equals('return !(y < 0.5) && !b;', reduce('{ if (y < 0.5) return false; if (b) return false; return true; }'));
	}

	/**
	 * PIN (not a discrimination test): an `Int` operand is totally ordered by `<`, so the flip
	 * is licensed and the output is byte-identical to what the unconditional mode emitted. This
	 * passes with the change reverted — that is the point: it pins the promise that proven-Int
	 * shapes did not move.
	 */
	public function testIntOrderedGuardStillFlips(): Void {
		Assert.equals('return x >= 0 && !b;', reduce('{ if (x < 0) return false; if (b) return false; return true; }'));
	}

	/**
	 * A declined flip never suppresses the reduction: unlike the guard family, this rule is not
	 * inverting a condition for readability — it is collapsing a multi-statement chain, and a
	 * wrapped operand is already its normal output for any opaque condition. So the site is
	 * still FLAGGED, just reduced with the wrap.
	 *
	 * PIN, not a discrimination test: flagging never consulted the type probe (the seam's
	 * null-ness is resolver-independent), so this passes with the change reverted too. What it
	 * pins is the deliberate decision NOT to add a decline gate here.
	 */
	public function testStringOrderedGuardStillFlagged(): Void {
		Assert.equals(1, violations('{ if (s < t) return false; if (b) return false; return true; }').length);
	}

	/** A condition in a POSITIVE (`return true`) guard is never negated, so its type is moot. */
	public function testStringOrderedGuardVerbatimWhenPositive(): Void {
		Assert.equals('return s < t || b;', reduce('{ if (s < t) return true; if (b) return true; return false; }'));
	}

	private function violations(body: String): Array<Violation> {
		final src: String =
			'class C { static function f(a: Bool, b: Bool, c: Bool, x: Int, s: String, t: String, y: Float): Dynamic ${body} }';
		return new SimplifyBooleanReturnChain().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The rewrite text the fix emits for the first chain in `body` (empty if none). */
	private function reduce(body: String): String {
		final src: String =
			'class C { static function f(a: Bool, b: Bool, c: Bool, x: Int, s: String, t: String, y: Float): Dynamic ${body} }';
		final check: SimplifyBooleanReturnChain = new SimplifyBooleanReturnChain();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
	}

}
