package unit.check.common.expressions;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.common.expressions.MixedLogicalParens;
import anyparse.check.common.expressions.RedundantParens;
import anyparse.query.CanonicalEdit;
import sys.io.File;
import unit.grammar.haxe.HxWriteFixture;

/**
 * The `mixed-logical-parens` check: a bare `&&` operand of `||`, on either side and at any depth of the `||` chain, is
 * flagged `Info` and parenthesized the way the parser already groups it. A written pair, a lone `&&` chain and a `||` chain
 * are left alone.
 */
class MixedLogicalParensCheckTest extends Test {

	public function testAndLeftOfOrFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('a && b || c'));
		Assert.equals(1, vs.length);
		Assert.equals('mixed-logical-parens', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testAndRightOfOrFlagged(): Void {
		Assert.equals(1, violations(wrap('a || b && c')).length);
	}

	/** Every `&&` group of a long `||` chain is its own finding. */
	public function testEveryGroupOfAChainFlagged(): Void {
		Assert.equals(3, violations(wrap('a && b || c || d && e || f && a')).length);
	}

	public function testFixWrapsEveryGroup(): Void {
		Assert.equals(wrap('(a && b) || c'), applyFix(wrap('a && b || c')));
		Assert.equals(wrap('(a /*k*/ && b) || c'), applyFix(wrap('a /*k*/ && b || c')));
		Assert.equals(wrap('a || (b && c)'), applyFix(wrap('a || b && c')));
		Assert.equals(wrap('(a && b) || c || (a && b && c)'), applyFix(wrap('a && b || c || a && b && c')));
	}

	public function testUnmixedAndWrittenPairsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('a && b && c')).length);
		Assert.equals(0, violations(wrap('a || b || c')).length);
		Assert.equals(0, violations(wrap('(a && b) || c')).length);
		Assert.equals(0, violations(wrap('a || (b && c)')).length);
	}

	/** A `||` under an `&&` is already parenthesized by the grammar; only the `&&` under `||` is the finding. */
	public function testOrUnderAndNotFlagged(): Void {
		Assert.equals(0, violations(wrap('a && (b || c)')).length);
	}

	/** The pair this rule writes must survive `redundant-parens`, or the two rules would undo each other. */
	public function testRedundantParensKeepsTheWrittenPair(): Void {
		Assert.equals(0, CheckFixture.violations(new RedundantParens(), wrap('(a && b) || c')).length);
		Assert.equals(0, CheckFixture.violations(new RedundantParens(), wrap('a || (b && c) || (a && c)')).length);
	}

	public function testDefaultOffAndRegistered(): Void {
		Assert.notNull(Linter.byId('mixed-logical-parens'));
		Assert.isTrue(Std.isOfType(Linter.byId('mixed-logical-parens'), DefaultOff));
	}

	/** Fix passes converge on nested groups: the outermost is wrapped first, the next pass wraps the group inside it. */
	public function testNestedGroupsConverge(): Void {
		Assert.equals(wrap('((a && b || c) && d) || e'), applyFix(wrap('(a && b || c) && d || e')));
		Assert.equals(wrap('(((a && b) || c) && d) || e'), applyFix(applyFix(wrap('(a && b || c) && d || e'))));
	}

	/** A group with a comment right after it stays reported and is never rewritten: the fix declines, the file stays as written. */
	public function testGroupWithCommentIsReportedNotFixed(): Void {
		for (expr in ['a && b // note\n\t\t\t|| c', 'a && b /* in */ || c']) {
			final src: String = 'class C {\n\n\tfunction f(a: Bool, b: Bool, c: Bool): Void {\n\t\tvar x = $expr;\n\t}\n\n}\n';
			Assert.equals(1, violations(src).length);
			switch CanonicalEdit.canonicalize(src, CheckFixture.edits(new MixedLogicalParens(), src), true, new HaxeQueryPlugin(), null) {
				case Ok(_):
					Assert.fail('the fix must decline a group carrying a comment: $expr');
				case Err(message):
					Assert.isTrue(message.indexOf('result does not parse') >= 0 || message.indexOf('losing the comment') >= 0, message);
			}
		}
	}

	/**
	 * Under the project's own formatter options the written pairs are what lays the chain out as groups: each `(x && y)`
	 * stays on one line and the chain breaks only at `||`, where the bare chain breaks at every operator.
	 */
	public function testParenthesizedChainLaysOutOneGroupPerLine(): Void {
		final config: String = File.getContent('hxformat.json');
		final head: String = 'class C {\n\tfunction f(alphaCondition:Bool, betaCondition:Bool, gammaCondition:Bool, deltaCondition:Bool, '
			+ 'epsilonCondition:Bool, zetaCondition:Bool):Bool {\n\t\treturn ';
		final tail: String = ';\n\t}\n}';
		final bare: String = 'alphaCondition.isEnabledForThisItem && betaCondition.isEnabledForThisItem || '
			+ 'gammaCondition.isEnabledForThisItem '
			+ '&& deltaCondition.isEnabledForThisItem || epsilonCondition.isEnabledForThisItem && zetaCondition.isEnabledForThisItem';
		final signature: String = 'class C {\n\n\tfunction f(\n\t\talphaCondition: Bool, betaCondition: Bool, gammaCondition: Bool, '
			+ 'deltaCondition: Bool, epsilonCondition: Bool, zetaCondition: Bool\n\t): Bool {\n\t\treturn ';
		final end: String = ';\n\t}\n\n}';
		Assert.equals(
			'$signature(alphaCondition.isEnabledForThisItem && betaCondition.isEnabledForThisItem)\n'
			+ '\t\t\t|| (gammaCondition.isEnabledForThisItem && deltaCondition.isEnabledForThisItem)\n'
			+ '\t\t\t|| (epsilonCondition.isEnabledForThisItem && zetaCondition.isEnabledForThisItem)$end',
			format(applyFix(head + bare + tail), config)
		);
		Assert.equals(
			'${signature}alphaCondition.isEnabledForThisItem\n\t\t\t&& betaCondition.isEnabledForThisItem\n'
			+ '\t\t\t|| gammaCondition.isEnabledForThisItem\n\t\t\t&& deltaCondition.isEnabledForThisItem\n'
			+ '\t\t\t|| epsilonCondition.isEnabledForThisItem\n\t\t\t&& zetaCondition.isEnabledForThisItem$end',
			format(head + bare + tail, config)
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f(a:Bool, b:Bool, c:Bool):Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new MixedLogicalParens(), src);
	}

	private function format(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new MixedLogicalParens(), src);
	}

}
