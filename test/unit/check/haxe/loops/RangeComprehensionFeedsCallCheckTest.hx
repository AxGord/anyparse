package unit.check.haxe.loops;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.haxe.loops.RangeComprehensionFeedsCall;

/**
 * The `range-comprehension-feeds-call` check: an identity comprehension over an integer range that a call consumes at
 * once — `[for (i in a...b) i].exists(f)` — builds an array only to walk it. `exists` and `foreach` that are the whole
 * value of a `return` in a block become a loop with an early return, the lambda parameter its binder; every other
 * site, and the calls with no such loop, is reported and left alone.
 */
class RangeComprehensionFeedsCallCheckTest extends Test {

	public function testExistsReturnIsFlaggedAndBecomesALoop(): Void {
		final source: String = wrap('return [for (i in k ... n + 1) i].exists(i -> g(i));');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('range-comprehension-feeds-call', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this range comprehension builds an array only for `.exists` to walk — loop over the range instead', vs[0].message);
		Assert.equals(wrap('for (i in k ... n + 1) if (g(i)) return true;\nreturn false;'), fixed(source));
	}

	/** The condition is written in terms of the lambda's parameter, so that is the name the loop binds. */
	@:pin('control')
	@:killer('M-RCFC-BINDER-FROM-COMPREHENSION')
	public function testLambdaParameterBecomesTheBinder(): Void {
		Assert.equals(
			wrap('for (d in 0...n) if (g(d)) return true;\nreturn false;'), fixed(wrap('return [for (i in 0...n) i].exists(d -> g(d));'))
		);
	}

	/** Every element must satisfy it, so the loop leaves at the first that does not: the negated condition returns false. */
	@:pin('control')
	@:killer('M-RCFC-FOREACH-NOT-NEGATED')
	public function testForeachReturnBecomesALoopOnTheNegatedCondition(): Void {
		final source: String = wrap('return [for (i in 0...n) i].foreach(d -> d > 0);');
		Assert.equals(1, violations(source).length);
		Assert.equals(wrap('for (d in 0...n) if (!(d > 0)) return false;\nreturn true;'), fixed(source));
		Assert.equals(
			wrap('for (d in 0...n) if (g(d) != k) return false;\nreturn true;'),
			fixed(wrap('return [for (i in 0...n) i].foreach(d -> g(d) == k);'))
		);
	}

	/** A call inside an `&&` chain or a ternary is no whole `return` value, so there is no statement to turn into a loop. */
	public function testCallInsideALargerValueIsReportOnly(): Void {
		for (statement in [
			'return n > 0 && [for (i in 0...n) i].foreach(d -> g(d));',
			'return h([for (i in 0...n) i].exists(d -> g(d)));'
		]) {
			Assert.equals(1, violations(wrap(statement)).length);
			Assert.equals(wrap(statement), fixed(wrap(statement)));
		}
	}

	/** Without a block the second statement would leave the `if` that guarded the first. */
	@:pin('control')
	@:killer('M-RCFC-ANY-PARENT-BLOCK')
	public function testReturnWithoutABlockIsReportOnly(): Void {
		final source: String = wrap('if (n > 0) return [for (i in 0...n) i].exists(d -> g(d));\n\t\treturn false;');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, fixed(source));
	}

	/** A call whose value is dropped or assigned is no `return` either. */
	@:pin('control')
	@:killer('M-RCFC-ANY-STATEMENT-FIXED')
	public function testCallThatIsNotReturnedIsReportOnly(): Void {
		for (statement in [
			'[for (i in 0...n) i].exists(d -> g(d));',
			'final r = [for (i in 0...n) i].exists(d -> g(d));'
		]) {
			Assert.equals(1, violations(wrap(statement)).length);
			Assert.equals(wrap(statement), fixed(wrap(statement)));
		}
	}

	/** `filter`, `map`, `count` and `find` walk the array too, but their result is no early exit a loop could return. */
	@:pin('control')
	@:killer('M-RCFC-EVERY-METHOD-FIXED')
	public function testOtherConsumingCallsAreReportOnly(): Void {
		for (method in ['filter', 'map', 'count', 'find']) {
			final source: String = wrap('return [for (i in 0...n) i].$method(d -> g(d));');
			final vs: Array<Violation> = violations(source);
			Assert.equals(1, vs.length);
			Assert.equals(
				'this range comprehension builds an array only for `.$method` to walk — loop over the range instead', vs[0].message
			);
			Assert.equals(source, fixed(source));
		}
	}

	/** An element that is computed, not handed back, is a real mapping. */
	@:pin('control')
	@:killer('M-RCFC-ANY-BODY')
	public function testComputedElementIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return [for (i in 0...n) i * 2].exists(d -> g(d));')).length);
		Assert.equals(0, violations(wrap('return [for (i in 0...n) g(i)].foreach(d -> d);')).length);
	}

	/** Only a range is iterable without an array; a collection's own elements are the array already. */
	@:pin('control')
	@:killer('M-RCFC-ANY-ITERABLE')
	public function testComprehensionOverACollectionIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return [for (x in xs) x].exists(d -> g(d));')).length);
	}

	@:pin('control')
	@:killer('M-RCFC-TYPED-PARAM-FIXED')
	public function testTypedLambdaParameterIsReportOnly(): Void {
		final source: String = wrap('return [for (i in 0...n) i].exists((d: Int) -> g(d));');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, fixed(source));
	}

	/** A `return` in the lambda's block leaves the lambda; in the loop it would leave the function. */
	@:pin('control')
	@:killer('M-RCFC-BLOCK-BODY-FIXED')
	public function testBlockBodyIsReportOnly(): Void {
		final source: String = wrap('return [for (i in 0...n) i].exists(d -> { return g(d); });');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, fixed(source));
	}

	@:pin('control')
	@:killer('M-RCFC-COMMENT-DROPPED')
	public function testCommentInDroppedTextIsReportOnly(): Void {
		final source: String = wrap('return [for (i in 0...n) i].exists(d -> g(d)) /* why */;');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, fixed(source));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { return [for (i in 0...n) i].exists(d ->').length);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('range-comprehension-feeds-call');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'range-comprehension-feeds-call is opt-in');
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new RangeComprehensionFeedsCall(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new RangeComprehensionFeedsCall(), src);
	}

	private static function wrap(statement: String): String {
		return 'class C {\n\tfunction f(n: Int, k: Int, xs: Array<Int>): Bool {\n\t\t$statement\n\t}\n}';
	}

}
