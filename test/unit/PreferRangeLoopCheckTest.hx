package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferRangeLoop;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

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
		final src: String = 'class C {\n\tfunction f(n:Int):Int {\n\t\tvar i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t\treturn i;\n\t}\n}';
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
		final src: String = 'class C {\n\tfunction f(a:Int, to:Int):Void {\n\t\tvar i = a < 0 ? 0 : a;\n\t\twhile (i < to) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}';
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
		final src: String = 'class C {\n\tfunction f(n:Float):Void {\n\t\tvar i = 0;\n\t\twhile (i < n) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}';
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
		Assert.notNull(Linter.byId('prefer-range-loop'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-range-loop'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(n:Int) { var i = 0; while (i < n) { work(i); i++; }').length);
	}

	public function testClosureCapturingCounterNotFlagged(): Void {
		// A closure capturing the counter sees its post-loop value under the while's shared
		// binding; a range for re-scopes i per iteration, so the transform is unsound — skip.
		Assert.equals(0, violations(wrapFn('var i = 0;\n\t\twhile (i < n) {\n\t\t\tqueue(() -> i);\n\t\t\ti++;\n\t\t}')).length);
	}

	private function wrapFn(body: String): String {
		return 'class C {\n\tfunction f(n:Int):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferRangeLoop().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final r = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): { check: PreferRangeLoop, vs: Array<Violation> } {
		final check: PreferRangeLoop = new PreferRangeLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

}
