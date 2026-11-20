package unit.check.common.loops;

import anyparse.check.Severity;
import anyparse.check.common.loops.RedundantIfBeforeWhile;
import anyparse.query.CanonicalEdit;

/**
 * The `redundant-if-before-while` check: `if (C) while (C) body` repeats the loop's own test in
 * the `if`, which decides nothing. The fix keeps the `while` and drops the `if`, and applies only
 * when `C` is pure; a `for`, a `do … while` and a wider `C && D` are never the pattern.
 */
class RedundantIfBeforeWhileCheckTest extends Test {

	public function testPureConditionFlaggedAndFixed(): Void {
		final src: String = wrap('if (n > 0) while (n > 0) n--;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-if-before-while', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		final text: String = fixed(src);
		Assert.isTrue(text.indexOf('while (n > 0) n--;') >= 0);
		Assert.isTrue(text.indexOf('if (') == -1);
	}

	@:pin('control')
	@:killer('M-RIBW-FIX-TEXT-EMPTY')
	public function testFixKeepsTheWhileSourceUnchanged(): Void {
		final text: String = fixed(wrap('if (n > 0 && n < 10) while (n > 0 && n < 10) n = n - 1;'));
		Assert.isTrue(text.indexOf('while (n > 0 && n < 10)') >= 0);
		Assert.isTrue(text.indexOf('n = n - 1;') >= 0);
		Assert.isTrue(text.indexOf('if (') == -1);
	}

	public function testBracedThenBlockWithOneStatementFixed(): Void {
		final text: String = fixed(wrap('if (n > 0) { while (n > 0) n--; }'));
		Assert.isTrue(text.indexOf('while (n > 0) n--;') >= 0);
		Assert.isTrue(text.indexOf('if (') == -1);
	}

	public function testBracedWhileBodyKept(): Void {
		final text: String = fixed(wrap('if (n > 0) while (n > 0) { n--; }'));
		Assert.isTrue(text.indexOf('while (n > 0)') >= 0);
		Assert.isTrue(text.indexOf('if (') == -1);
	}

	@:pin('control')
	@:killer('M-RIBW-IMPURE-OK')
	public function testUnprovenCallIsReportedButNotFixed(): Void {
		final src: String = wrap(
			'if (s.length > 0 && !isOneOf(s.charAt(0), set)) while (s.length > 0 && !isOneOf(s.charAt(0), set)) s = s.substr(1);'
		);
		final check: RedundantIfBeforeWhile = new RedundantIfBeforeWhile();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('not proven pure') >= 0);
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length);
	}

	@:pin('control')
	@:killer('M-RIBW-ELSE-IGNORED')
	public function testIfWithElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (n > 0) while (n > 0) n--; else n = 1;')).length);
	}

	@:pin('guard')
	public function testDoWhileNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (n > 0) do n--; while (n > 0);')).length);
	}

	@:pin('guard')
	public function testForLoopNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (n > 0) for (i in 0...n) n--;')).length);
	}

	@:pin('control')
	@:killer('M-RIBW-EQUAL-ALWAYS')
	public function testWiderIfConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (n > 0 && s != null) while (n > 0) n--;')).length);
	}

	@:pin('control')
	@:killer('M-RIBW-EQUAL-ALWAYS')
	public function testDifferentLiteralInConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (n > 0) while (n > 1) n--;')).length);
	}

	@:pin('guard')
	public function testSecondStatementInBlockNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (n > 0) { while (n > 0) n--; n = 1; }')).length);
	}

	@:pin('control')
	@:killer('M-RIBW-ANY-STATEMENT')
	public function testNestedIfWithSameConditionIsNotAWhile(): Void {
		Assert.equals(0, violations(wrap('if (n > 0) if (n > 0) n--;')).length);
	}

	@:pin('control')
	@:killer('M-RIBW-COMMENT-LOST')
	public function testCommentBetweenIfAndWhileKeepsTheFindingReportOnly(): Void {
		final src: String = wrap('if (n > 0)\n\t\t\t// keep this\n\t\t\twhile (n > 0) n--;');
		final check: RedundantIfBeforeWhile = new RedundantIfBeforeWhile();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('comment') >= 0);
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length);
	}

	public function testCommentInsideTheWhileSurvivesTheFix(): Void {
		final text: String = fixed(wrap('if (n > 0) while (n > 0) {\n\t\t\t// keep this\n\t\t\tn--;\n\t\t}'));
		Assert.isTrue(text.indexOf('// keep this') >= 0);
		Assert.isTrue(text.indexOf('if (') == -1);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tstatic function isOneOf(c:String, set:String):Bool return set.indexOf(c) >= 0;\n'
			+ '\tfunction f(n:Int, s:String, set:String):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new RedundantIfBeforeWhile(), source);
	}

	/** The source after the check's fix, canonicalized; `ERR: …` when the edit does not round-trip. */
	private function fixed(src: String): String {
		final check: RedundantIfBeforeWhile = new RedundantIfBeforeWhile();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		return switch CanonicalEdit.canonicalize(src, CheckFixture.fixOf(check, src, vs), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): 'ERR: $message';
		};
	}

}
