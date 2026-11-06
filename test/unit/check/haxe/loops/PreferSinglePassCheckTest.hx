package unit.check.haxe.loops;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Severity;
import anyparse.check.haxe.loops.PreferSinglePass;

/**
 * The `prefer-single-pass` check: an `Array` chain `filter.map`, `map.map`, `filter.filter` or `map.filter` walks the array
 * twice and is flagged `Info`. The fix merges the two lambdas only where both bodies are pure, neither can be captured by
 * the other's binder and at most one of them can throw, so interleaving them changes nothing; everything else, and
 * `map.filter` always, stays report-only.
 */
class PreferSinglePassCheckTest extends Test {

	public function testFilterMapFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('final ys = xs.filter(x -> x > 1).map(x -> x * 2);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-single-pass', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this filter(…).map(…) walks the array twice — [for (x in xs) if (p) f] does it in one pass', vs[0].message);
	}

	public function testFilterMapBecomesComprehension(): Void {
		Assert.equals(
			wrap('final ys = [for (x in xs) if (x > 1) x * 2];'), fixed(wrap('final ys = xs.filter(x -> x > 1).map(x -> x * 2);'))
		);
	}

	/** The second lambda's binder is renamed to the first's. */
	public function testSecondBinderTakesTheFirstName(): Void {
		Assert.equals(
			wrap('final ys = [for (a in xs) if (a > 1) a * 2];'), fixed(wrap('final ys = xs.filter(a -> a > 1).map(b -> b * 2);'))
		);
	}

	public function testMapMapBecomesOneMap(): Void {
		Assert.equals(wrap('final ys = xs.map(x -> (x + 1) * 2);'), fixed(wrap('final ys = xs.map(x -> x + 1).map(y -> y * 2);')));
		Assert.equals(wrap('final ys = xs.map(x -> (x + 1) * 2);'), fixed(wrap('final ys = xs.map(x -> x + 1).map(x -> x * 2);')));
		Assert.equals(1, violations(wrap('final ys = xs.map(x -> x + 1).map(y -> y * 2);')).length);
	}

	public function testFilterFilterBecomesOneFilter(): Void {
		Assert.equals(
			wrap('final ys = xs.filter(x -> x > 1 && x < 9);'), fixed(wrap('final ys = xs.filter(x -> x > 1).filter(y -> y < 9);'))
		);
	}

	/** The receiver keeps its parentheses in the rewrite. */
	public function testParenthesisedReceiverKeepsItsParentheses(): Void {
		Assert.equals(
			wrap('final ys = (k > 0 ? xs : xs).filter(x -> x > 1 && x < 3);'),
			fixed(wrap('final ys = (k > 0 ? xs : xs).filter(x -> x > 1).filter(y -> y < 3);'))
		);
	}

	/**
	 * A rename reaches identifier nodes only, so an interpolated `$y` or `$k` would keep its old name: the merge is held back
	 * by the purity proof, which refuses a string with an interpolated identifier or block.
	 */
	@:pin('control')
	@:killer('M-PSP-PURE')
	public function testInterpolatedReadIsReportOnly(): Void {
		for (src in [
			wrap('final ys = xs.filter(x -> x > 1).map(y -> \'$$y\');'),
			wrap('final ys = xs.filter(x -> x > 1).map(y -> \'$${y}\');'),
			wrap('final ys = xs.filter(k -> k > 0).map(b -> \'$$k\');')
		]) {
			Assert.equals(1, violations(src).length);
			Assert.equals(src, fixed(src));
		}
	}

	/** An `||` operand binds looser than the `&&` that joins it. */
	@:pin('control')
	@:killer('M-PSP-AND-WRAP')
	public function testLooserOperandIsParenthesised(): Void {
		Assert.equals(
			wrap('final ys = xs.filter(x -> (x > 1 || x < -5) && x != 3);'),
			fixed(wrap('final ys = xs.filter(x -> x > 1 || x < -5).filter(y -> y != 3);'))
		);
	}

	/** `f` would run twice in a one-call spelling, so there is only the report. */
	@:pin('guard')
	public function testMapFilterIsReportOnly(): Void {
		final src: String = wrap('final ys = xs.map(x -> x + 1).filter(y -> y > 1);');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'this map(…).filter(…) walks the array twice — [for (x in xs) { final y = f; if (p) y; }] does it in one pass', vs[0].message
		);
		Assert.equals(src, fixed(src));
	}

	/** `List.filter` and `List.map` return a `List`: only an `Array` chain is flagged. */
	@:pin('control')
	@:killer('M-PSP-ANY-RECEIVER')
	public function testOtherCollectionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = ls.filter(x -> x > 1).map(x -> x * 2);')).length);
	}

	/** A body that calls something unproven pure may move relative to the other: the report stays, the rewrite does not. */
	@:pin('control')
	@:killer('M-PSP-PURE')
	public function testImpureBodyIsReportOnly(): Void {
		final first: String = wrap('final ys = xs.filter(x -> one(x) > 1).map(x -> x * 2);');
		final second: String = wrap('final ys = xs.filter(x -> x > 1).map(x -> one(x));');
		Assert.equals(1, violations(first).length);
		Assert.equals(1, violations(second).length);
		Assert.equals(first, fixed(first));
		Assert.equals(second, fixed(second));
	}

	/** Two bodies that can both throw would surface a different exception once interleaved. */
	@:pin('control')
	@:killer('M-PSP-THROW')
	public function testTwoThrowingBodiesAreReportOnly(): Void {
		final src: String = wrap('final ys = xs.filter(x -> x % k == 0).map(x -> x % k);');
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixed(src));
		final fields: String = wrap('final ys = ps.filter(p -> p.a > 0).map(p -> p.b);');
		Assert.equals(1, violations(fields).length);
		Assert.equals(fields, fixed(fields));
	}

	public function testOneThrowingBodyIsMerged(): Void {
		Assert.equals(
			wrap('final ys = [for (x in xs) if (x % k == 0) x * 2];'),
			fixed(wrap('final ys = xs.filter(x -> x % k == 0).map(x -> x * 2);'))
		);
		Assert.equals(
			wrap('final ys = [for (x in xs) if (x > 0) x % k];'), fixed(wrap('final ys = xs.filter(x -> x > 0).map(x -> x % k);'))
		);
	}

	/** `g` can sit under a short circuit that skips `f`, so a throwing `f` must not be merged into it. */
	@:pin('control')
	@:killer('M-PSP-MAPMAP-FIRST')
	public function testMapMapNeedsTheFirstBodyToBeThrowFree(): Void {
		final src: String = wrap('final ys = xs.map(x -> x % k).map(y -> y + 1);');
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixed(src));
		Assert.equals(wrap('final ys = xs.map(x -> (x + 1) % k);'), fixed(wrap('final ys = xs.map(x -> x + 1).map(y -> y % k);')));
	}

	/** The merged body sits under the first binder, which would capture a read of that name in the second. */
	@:pin('control')
	@:killer('M-PSP-CAPTURE')
	public function testBinderCapturingASecondBodyReadIsReportOnly(): Void {
		final src: String = wrap('final ys = xs.filter(k -> k > 0).map(b -> b + k);');
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	/** `g` reading `f`'s result twice would run `f` twice; reading it never would drop `f`. */
	@:pin('control')
	@:killer('M-PSP-SINGLE-READ')
	public function testMapMapNeedsOneReadOfTheResult(): Void {
		final twice: String = wrap('final ys = xs.map(x -> x + 1).map(y -> y * y);');
		final never: String = wrap('final ys = xs.map(x -> x + 1).map(y -> 5);');
		Assert.equals(1, violations(twice).length);
		Assert.equals(1, violations(never).length);
		Assert.equals(twice, fixed(twice));
		Assert.equals(never, fixed(never));
	}

	/** A typed parameter would lose its annotation, a block body is no expression and a function value is no lambda. */
	@:pin('control')
	@:killer('M-PSP-TYPED-PARAM')
	public function testLambdaShapeDecidesTheRewrite(): Void {
		final typed: String = wrap('final ys = xs.filter((x: Int) -> x > 1).map(x -> x * 2);');
		final block: String = wrap('final ys = xs.filter(x -> { return x > 1; }).map(x -> x * 2);');
		final callee: String = wrap('final ys = xs.filter(isBig).map(x -> x * 2);');
		for (src in [typed, block, callee]) {
			Assert.equals(1, violations(src).length);
			Assert.equals(src, fixed(src));
		}
	}

	/** The rewrite drops the punctuation between the pieces, and a comment there would go with it. */
	@:pin('control')
	@:killer('M-PSP-COMMENT')
	public function testCommentBetweenThePiecesIsReportOnly(): Void {
		final src: String = wrap('final ys = xs.filter(x -> x > 1) /* keep */ .map(x -> x * 2);');
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	/** The outer pair is merged first; what it leaves is the next pass. */
	public function testLongerChainMergesItsLastPair(): Void {
		final src: String = wrap('final ys = xs.map(x -> x + 1).filter(y -> y > 1).map(z -> z * 2);');
		Assert.equals(1, violations(src).length);
		Assert.equals(wrap('final ys = [for (y in xs.map(x -> x + 1)) if (y > 1) y * 2];'), fixed(src));
	}

	public function testOtherChainsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = xs.filter(x -> x > 1).length;')).length);
		Assert.equals(0, violations(wrap('final ys = xs.map(x -> x + 1);')).length);
		Assert.equals(0, violations(wrap('final ys = xs.filter(x -> x > 1).concat(xs);')).length);
	}

	public function testDefaultOffAndRisky(): Void {
		Assert.isTrue(Std.isOfType(new PreferSinglePass(), DefaultOff));
		Assert.isTrue(Std.isOfType(new PreferSinglePass(), RiskyFix));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferSinglePass(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new PreferSinglePass(), src);
	}

	private static function wrap(statement: String): String {
		return 'class C extends B {\n\tvar fld: Int = 0;\n\n\tfunction one(a: Int): Int {\n\t\treturn a;\n\t}\n\n'
			+ '\tfunction isBig(a: Int): Bool {\n\t\treturn a > 1;\n\t}\n\n'
			+ '\tfunction f(xs: Array<Int>, ls: List<Int>, ps: Array<P>, k: Int): Void {\n\t\t$statement\n\t}\n}';
	}

}
