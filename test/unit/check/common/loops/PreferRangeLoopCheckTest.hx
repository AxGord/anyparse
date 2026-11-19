package unit.check.common.loops;

import anyparse.check.Severity;
import anyparse.check.common.loops.PreferRangeLoop;
import anyparse.query.CanonicalEdit;

/**
 * The `prefer-range-loop` check: a `var i = A;` immediately followed by
 * `while (i < B) { … i++; }` is flagged `Info`, report-only (the `for (i in A...B)`
 * rewrite is sound only under every gate, several of which are the analyses most
 * likely to hide a subtle bug). Soundness misses: an `i <= B` / reversed / `!=`
 * condition, an extra write of `i` in the body, `i` read after the loop, a non-simple
 * bound `B` (a call / field access) or a bound identifier written in the body, a
 * `continue` in the body, a non-adjacent declaration, a `final` counter, a shadowing
 * re-declaration of `i`, a `++i` / `i += 1` increment, and an empty body. A `break`
 * is fine (same semantics), a literal bound and a typed declaration flag.
 */
class PreferRangeLoopCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-range-loop', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this var-counter while loop can be for (i in 0...n)', vs[0].message);
	}

	public function testTypedDeclFlagged(): Void {
		Assert.equals(1, violations(wrapFn('var i:Int = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testLiteralBoundFlagged(): Void {
		final vs: Array<Violation> = violations(wrapFn('var i = 0;\n\t\twhile (i < 10) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('this var-counter while loop can be for (i in 0...10)', vs[0].message);
	}

	public function testExpressionInitFlagged(): Void {
		final vs: Array<Violation> = violations(wrapFn('var i = start + 1;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('this var-counter while loop can be for (i in start + 1...n)', vs[0].message);
	}

	public function testBreakInBodyFlagged(): Void {
		Assert.equals(1, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\tif (done(i)) break;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testLessEqualNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i <= n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testReversedConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (n > i) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testExtraWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\ti--;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testPreIncrementNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\t++i;\n\t\t}')).length);
	}

	public function testAddAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti += 1;\n\t\t}')).length);
	}

	public function testReadAfterNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(n:Int):Int {\n\t\tvar i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n'
			+ '\t\treturn i;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testBoundCallNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < items.length) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testBoundWrittenNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\tn = 5;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testBoundCompoundAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\tn += 1;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testIncrementInTrailingIfNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\tif (cond(i)) i++;\n\t\t}')).length);
	}

	public function testNestedWhileSharingCounterNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\twhile (i < n) i++;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testContinueNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\tif (skip(i)) continue;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twork(0);\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testFinalDeclNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('final i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testShadowedNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\tvar i = 5;\n\t\t\ttrace(i);\n\t\t\ti++;\n\t\t}')).length
		);
	}

	public function testEmptyBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testTrailingNonIncrementNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\ti++;\n\t\t\twork(i);\n\t\t}')).length);
	}

	public function testFixRewritesToRangeLoop(): Void {
		assertFixCanonical(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'), 'for (i in 0...n)', 'while (');
	}

	public function testFixParenthesisesTernaryBound(): Void {
		final src: String = 'class C {\n\tfunction f(a:Int, to:Int):Void {\n\t\tvar i = a < 0 ? 0 : a;\n\t\twhile (i < to) {\n'
			+ '\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}';
		assertFixCanonical(src, 'for (i in (a < 0 ? 0 : a)...to)', 'while (');
	}

	public function testFixRefusesLeadingComment(): Void {
		// A comment between the declaration and the while would be dropped by the rewrite, so the fix refuses it.
		assertFixRefused(wrapFn('var i = 0;\n\t\t// setup done\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'));
	}

	public function testFloatCounterNotFlagged(): Void {
		// Haxe's ... interval requires Int operands; a declared Float counter cannot become a range loop.
		Assert.equals(0, violations(wrapFn('var i:Float = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testFloatBoundNotFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f(n:Float):Void {\n\t\tvar i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFloatLiteralBoundNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < 1.5) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testFixRefusesTrailingComment(): Void {
		// A comment between i++ and the block's } would be dropped by the rewrite, so the fix refuses it.
		assertFixRefused(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t\t// keep\n\t\t}'));
	}

	public function testRegisteredInBuiltins(): Void {
		CheckFixture.assertRegistered('prefer-range-loop');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(n:Int) { var i = 0; while (i < n) { work(i); i++; }').length);
	}

	public function testClosureCapturingCounterNotFlagged(): Void {
		// A closure capturing the counter sees its post-loop value under the while's shared
		// binding; a range for re-scopes i per iteration, so the transform is unsound — skip.
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\tqueue(() -> i);\n\t\t\ti++;\n\t\t}')).length);
	}

	/** A named function expression or an `inline` local function capturing the counter bails as a lambda does. */
	public function testEveryNestedFunctionFormCapturingCounterNotFlagged(): Void {
		for (capture in [
			'queue(function named() return i);',
			'inline function named() return i;\n\t\t\tqueue(named);'
		]) Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\t$capture\n\t\t\ti++;\n\t\t}')).length, capture);
	}

	public function testStepInConditionFourFormsFixAndFold(): Void {
		for (c in [
			{ cond: 'a++ < 36', range: '9...37' },
			{ cond: '++a < 36', range: '9...36' },
			{ cond: 'a++ <= 36', range: '9...38' },
			{ cond: '++a <= 36', range: '9...37' }
		])
			assertFixCanonical(
				wrapFn('var a:Int = 8;\n\t\tlog.add(x);\n\t\twhile (${c.cond})\n\t\t\tlog.add(f(a));'), 'for (a in ${c.range})', 'var a'
			);
	}

	public function testStepInConditionNonLiteralBounds(): Void {
		assertFixCanonical(
			wrapFn('var a = start + 2;\n\t\twhile (a++ < n) {\n\t\t\twork(a);\n\t\t}'), 'for (a in (start + 2) + 1...n + 1)', 'while'
		);
		assertFixCanonical(wrapFn('var a = 0;\n\t\twhile (++a <= n) {\n\t\t\twork(a);\n\t\t}'), 'for (a in 1...n + 1)', 'while');
	}

	public function testStepInConditionRefusals(): Void {
		for (src in [
			'var a = 0;\n\t\twhile (a++ < n) work(a);\n\t\tuse(a);',
			'var a = 0;\n\t\twhile (a++ < n) {\n\t\t\ta = 5;\n\t\t}',
			'var a = 0;\n\t\tlog(a);\n\t\twhile (a++ < n) work(a);',
			'var a = 0;\n\t\ta = 3;\n\t\twhile (a++ < n) work(a);',
			'var a = n;\n\t\tn = 3;\n\t\twhile (a++ < 9) work(a);',
			'var a = 0;\n\t\twhile (a++ < n) {\n\t\t\tn--;\n\t\t}',
			'var a = 0;\n\t\twhile (a++ < f(n)) work(a);'
		]) Assert.equals(0, violations(wrapFn(src)).length, src);
	}

	public function testStepInConditionKeepsUntouchedStatementsAndContinue(): Void {
		assertFixCanonical(
			wrapFn('var a = 0;\n\t\tlog(x);\n\t\twhile (a++ < n) {\n\t\t\tif (a > 2) continue;\n\t\t\twork(a);\n\t\t}'),
			'log(x);\n\t\tfor (a in 1...n + 1) {', 'var a'
		);
	}

	@:pin('control')
	@:killer('M-PRL-STEP-BETWEEN-READ-IGNORED')
	public function testStepBetweenStatementReadingCounterRefused(): Void {
		Assert.equals(0, violations(wrapFn('var a = 0;\n\t\tlog(a);\n\t\twhile (a++ < n) work(a);')).length);
	}

	@:pin('control')
	@:killer('M-PRL-STEP-BODY-WRITE-IGNORED')
	public function testStepBodyWritingCounterRefused(): Void {
		Assert.equals(0, violations(wrapFn('var a = 0;\n\t\twhile (a++ < n) {\n\t\t\ta = 5;\n\t\t}')).length);
	}

	@:pin('control')
	@:killer('M-PRL-READ-AFTER-IGNORED')
	public function testStepCounterReadAfterLoopRefused(): Void {
		Assert.equals(0, violations(wrapFn('var a = 0;\n\t\twhile (a++ < n) work(a);\n\t\tuse(a);')).length);
	}

	@:pin('control')
	@:killer('M-PRL-INIT-SURVIVES-ANYTHING')
	public function testStepInitRedeclaredBetweenRefused(): Void {
		Assert.equals(
			0,
			violations(wrapFn('var k = 1;\n\t\t{\n\t\t\tvar i = k;\n\t\t\tvar k = 50;\n\t\t\twhile (i++ < n) work(i + k);\n\t\t}')).length
		);
	}

	@:pin('control')
	@:killer('M-PRL-INIT-SURVIVES-ANYTHING')
	public function testStepInitFieldWithCallBetweenRefused(): Void {
		final src: String = 'class C {\n\tvar s:Int = 0;\n\tfunction bump():Void {\n\t\ts = 10;\n\t}\n\tfunction f(n:Int):Void {\n'
			+ '\t\tvar i = s;\n\t\tbump();\n\t\twhile (i++ < n) work(i);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('control')
	@:killer('M-PRL-INIT-SURVIVES-ANYTHING')
	public function testStepInitLocalWrittenByClosureRefused(): Void {
		Assert.equals(
			0, violations(wrapFn('var s = 0;\n\t\tfunction inc() s = 10;\n\t\tvar i = s;\n\t\tinc();\n\t\twhile (i++ < n) work(i);')).length
		);
	}

	@:pin('control')
	@:killer('M-PRL-NEGATED-LITERAL-UNFOLDED')
	public function testStepNegatedLiteralInitFolds(): Void {
		assertFixCanonical(wrapFn('var i = -1;\n\t\twhile (++i < n) {\n\t\t\twork(i);\n\t\t}'), 'for (i in 0...n)', 'while');
	}

	public function testStepUntouchedLocalInitSurvivesBetween(): Void {
		assertFixCanonical(
			wrapFn('var k = 2;\n\t\tvar i = k;\n\t\tlog(x);\n\t\twhile (i++ < n) work(i);'), 'for (i in k + 1...n + 1)', 'var i'
		);
	}

	private function wrapFn(body: String): String {
		return 'class C {\n\tfunction f(n:Int):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new PreferRangeLoop(), source);
	}

	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final r: { vs: Array<Violation>, check: PreferRangeLoop } = runAndExpectOne(src);
		switch CanonicalEdit.canonicalize(src, CheckFixture.fixOf(r.check, src, r.vs), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r: { vs: Array<Violation>, check: PreferRangeLoop } = runAndExpectOne(src);
		Assert.equals(0, CheckFixture.fixOf(r.check, src, r.vs).length);
	}

	private function runAndExpectOne(src: String): { check: PreferRangeLoop, vs: Array<Violation> } {
		final check: PreferRangeLoop = new PreferRangeLoop();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

}
