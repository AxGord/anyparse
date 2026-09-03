package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.JoinBranchCall;
import anyparse.check.Linter;
import anyparse.check.PreferTernaryExpression;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `join-branch-call` check: an `if / else if / … / else` chain whose every branch is the SAME
 * call differing in exactly one argument is flagged `Info`, and `fix` sinks the branching into that
 * argument -- `f(a, if (c1) x else if (c2) y else z)`. The 2-branch case is claimed too; the
 * ternary downgrade is `prefer-ternary-expression`'s, one `--fix` pass later.
 */
class JoinBranchCallCheckTest extends Test {

	public function testChainFlagged(): Void {
		assertOneFinding(wrap('if (a) log(1);\n\t\telse if (b) log(2);\n\t\telse log(3);'));
	}

	public function testFixThreeBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) log(1);\n\t\telse if (b) log(2);\n\t\telse log(3);'));
		Assert.equals(1, es.length);
		Assert.equals('log(if (a) 1 else if (b) 2 else 3);', es[0].text);
	}

	/** The 2-branch shape is this rule's too -- unlike the assignment family, which reserves it for the ternary rule. */
	public function testFixTwoBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) log(1);\n\t\telse log(2);'));
		Assert.equals(1, es.length);
		Assert.equals('log(if (a) 1 else 2);', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\tlog(1);\n\t\t} else if (b) {\n\t\t\tlog(2);\n\t\t} else {\n\t\t\tlog(3);\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('log(if (a) 1 else if (b) 2 else 3);', es[0].text);
	}

	/** A receiver is part of the callee, so a method call folds exactly like a plain one. */
	public function testReceiverCallFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) items.push("x");\n\t\telse if (b) items.push("y");\n\t\telse items.push("z");'));
		Assert.equals(1, es.length);
		Assert.equals('items.push(if (a) "x" else if (b) "y" else "z");', es[0].text);
	}

	/** The varying argument keeps its position: the surviving call is split around it, not rebuilt. */
	public function testVaryingMiddleArgumentFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) log("p", 1, "z");\n\t\telse if (b) log("p", 2, "z");\n\t\telse log("p", 3, "z");'));
		Assert.equals(1, es.length);
		Assert.equals('log("p", if (a) 1 else if (b) 2 else 3, "z");', es[0].text);
	}

	/** End to end through the canonical writer -- the `lint --fix` path in one pass. */
	public function testApplyFixOnce(): Void {
		final out: String = applyFixOnce(wrap('if (a) log(1);\n\t\telse if (b) log(2);\n\t\telse log(3);'));
		Assert.isTrue(out.indexOf('log(if (a) 1 else if (b) 2 else 3);') != -1);
		Assert.isTrue(out.indexOf('else log(3)') == -1);
	}

	/** A chain with no terminal `else` leaves the argument with no value on the missing path. */
	public function testNoTerminalElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(1);\n\t\telse if (b) log(2);')).length);
	}

	public function testDifferentCalleeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(1);\n\t\telse if (b) warn(2);\n\t\telse log(3);')).length);
	}

	public function testDifferentArgumentCountNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(1);\n\t\telse if (b) log(2, 3);\n\t\telse log(4);')).length);
	}

	/** Two varying arguments cannot become one if-expression without evaluating the conditions twice. */
	public function testTwoVaryingArgumentsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(1, 2);\n\t\telse log(3, 4);')).length);
	}

	/** Identical branches are `tail-merge` / `duplicate-code` territory -- folding them would hide that the `if` is pointless. */
	public function testIdenticalCallsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(1);\n\t\telse log(1);')).length);
	}

	/** With no argument there is nothing for the branching to sink into. */
	public function testArgumentlessCallNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log();\n\t\telse log();')).length);
	}

	/** The receiver is hoisted ACROSS the conditions, so it must be pure -- a call in it refuses. */
	public function testImpureReceiverNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) get().push(1);\n\t\telse get().push(2);')).length);
	}

	/** A common argument is hoisted with the callee and must be pure for the same reason. */
	public function testImpureCommonArgumentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(now(), 1);\n\t\telse log(now(), 2);')).length);
	}

	/** A condition that can WRITE would be observed by the hoisted reads only in the ORIGINAL order. */
	public function testImpureConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (reset()) log(1);\n\t\telse log(2);')).length);
	}

	/** A branch value ending an expression OPEN would absorb the emitted ` else ` and swallow the rest of the chain. */
	public function testElseLessConditionalBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(if (q) 1);\n\t\telse log(2);')).length);
	}

	/** An assignment chain is the `prefer-*-assignment` family's shape, never this one's. */
	public function testAssignmentBranchesNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;')).length);
	}

	/** A deliberately grouped multi-statement branch is never collapsed. */
	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tlog(1);\n\t\t\tlog(2);\n\t\t} else log(3);')).length);
	}

	/** A comment in a region the rebuild drops -- here another branch's repeated callee -- fails the site closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) log(1);\n\t\telse /* why */ log(2);')).length);
	}

	/** Only the chain HEAD is flagged; its `else if` links belong to that chain. */
	public function testOneFindingPerChain(): Void {
		Assert.equals(1, violations(wrap('if (a) log(1);\n\t\telse if (b) log(2);\n\t\telse if (c) log(3);\n\t\telse log(4);')).length);
	}

	/**
	 * The VALUE position is claimed too. A branch value there is a bare call EXPRESSION rather than
	 * a call statement, and the head span ends at the last branch value -- the enclosing declaration
	 * owns the `;`.
	 */
	public function testValueChainFlagged(): Void {
		assertOneFinding(wrap('final e = if (a) log(1) else if (b) log(2) else log(3);'));
	}

	/** The rebuilt value carries NO `;` -- the replaced span stops at the last branch value. */
	public function testFixValueThreeBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final e = if (a) log(1) else if (b) log(2) else log(3);'));
		Assert.equals(1, es.length);
		Assert.equals('log(if (a) 1 else if (b) 2 else 3)', es[0].text);
	}

	public function testFixValueTwoBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('final e = if (a) log(1) else log(2);'));
		Assert.equals(1, es.length);
		Assert.equals('log(if (a) 1 else 2)', es[0].text);
	}

	public function testValueChainInReturnFixed(): Void {
		Assert.equals('${wrap('return log(if (a) 1 else 2);')}\n', applyFixOnce(wrap('return if (a) log(1) else log(2);')));
	}

	/** A chain nested as a call ARGUMENT is a value position like any other. */
	public function testValueChainAsArgumentFixed(): Void {
		Assert.equals('${wrap('f(g(if (a) 1 else 2));')}\n', applyFixOnce(wrap('f(if (a) g(1) else g(2));')));
	}

	/** End to end: the joined call lands AND the declaration keeps exactly one `;`. */
	public function testApplyFixOnceValueChain(): Void {
		final out: String = applyFixOnce(wrap('final e = if (a) log(1) else if (b) log(2) else log(3);'));
		Assert.equals('${wrap('final e = log(if (a) 1 else if (b) 2 else 3);')}\n', out);
	}

	/** An else-less value chain leaves the argument with no value on the missing path. */
	public function testElseLessValueChainNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final e = if (a) log(1);')).length);
	}

	/**
	 * A BRACED value branch parses as a `BlockExpr`, which is neither the call kind nor the block
	 * STATEMENT kind, and no `blockExprKind` seam exists to unwrap it -- so the site refuses. A
	 * deliberate boundary: the statement position collapses its braced form, the value position
	 * does not.
	 */
	public function testBracedValueBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final e = if (a) { log(1); } else log(2);')).length);
	}

	/** The else-less-absorption guard reaches the value position too -- the kinds it scans union both. */
	public function testElseLessConditionalInValueBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final e = if (q) log(if (p) 1) else log(2);')).length);
	}

	/** A condition that can WRITE would be observed by the hoisted reads only in the ORIGINAL order. */
	public function testImpureConditionInValueChainNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final e = if (reset()) log(1) else log(2);')).length);
	}

	public function testOneFindingPerValueChain(): Void {
		Assert.equals(1, violations(wrap('final e = if (a) log(1) else if (b) log(2) else if (c) log(3) else log(4);')).length);
	}

	/**
	 * The `;`-separated value chain -- the ONLY shape whose replaced span holds terminator tokens.
	 * The parser absorbs each inner `;` into the branch it follows, so the rebuild drops them and
	 * the enclosing declaration keeps the one that is really its own.
	 */
	public function testSemicolonSeparatedValueChainFixed(): Void {
		Assert.equals(
			'${wrap('final e = g(if (a) 1 else if (b) 2 else 3);')}\n',
			applyFixOnce(wrap('final e = if (a) g(1); else if (b) g(2); else g(3);'))
		);
	}

	/**
	 * A value chain nested in a STATEMENT chain's branch: claiming both positions makes the two
	 * overlap for the first time, and `RefactorSupport.dropContainedEdits` keeps only the outer.
	 * The inner one is reclaimed by the next `--fix` pass.
	 */
	public function testNestedStatementAndValueChainsEmitOuterOnly(): Void {
		final src: String = wrap('if (p) log(if (a) g(1) else g(2));\n\t\telse log(3);');
		Assert.equals(2, violations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('log(if (p) if (a) g(1) else g(2) else 3);', es[0].text);
	}

	/** A comment past the last branch value is INSIDE the head span, so the fail-closed guard refuses. */
	public function testTrailingCommentValueChainNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final e = if (a) log(1) else log(2) /* tail */;')).length);
	}

	/**
	 * The ordering contract, exercised through the DEFAULT rule set rather than `--rule` (which
	 * force-enables and reorders, so it cannot see this). `prefer-ternary-expression` sits EARLIER
	 * in `Linter.builtins()` and `Cli.computeFileLintEdits` keeps the earlier check's overlapping
	 * edit -- so without `JoinBranchCall.claims` a 2-branch value chain drew TWO contradictory
	 * advisories and `--fix` wrote the callee twice (`a ? log(1) : log(2)`).
	 */
	public function testTernaryDefersToThisRuleOnValueChain(): Void {
		final src: String = wrap('final e = if (a) log(1) else log(2);');
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final claimed: Array<String> = [
			for (check in Linter.builtins()) for (v in check.run(files, plugin))
				if (v.rule == 'join-branch-call' || v.rule == 'prefer-ternary-expression') v.rule
		];
		Assert.equals('join-branch-call', claimed.join(','));
	}

	/** The 2-branch STATEMENT chain keeps the ternary handoff -- the value it emits is no longer a call. */
	public function testStatementChainStillReachesTernary(): Void {
		final joined: String = applyFixOnce(wrap('if (a) log(1);\n\t\telse log(2);'));
		Assert.isTrue(joined.indexOf('log(if (a) 1 else 2);') != -1);
		final after: Array<Violation> = new PreferTernaryExpression().run([{ file: 'C.hx', source: joined }], new HaxeQueryPlugin());
		Assert.equals(1, after.length);
	}

	/** The VALUE arm reaches the ternary on the NEXT `--fix` pass, its branch values no longer calls. */
	public function testValueChainStillReachesTernary(): Void {
		final joined: String = applyFixOnce(wrap('final e = if (a) log(1) else log(2);'));
		Assert.isTrue(joined.indexOf('log(if (a) 1 else 2);') != -1);
		Assert.equals(1, new PreferTernaryExpression().run([{ file: 'C.hx', source: joined }], new HaxeQueryPlugin()).length);
	}

	/**
	 * Arguments differing ONLY by whitespace inside a string literal are DIFFERENT arguments.
	 * The shared-argument key was whitespace-normalised source (`IfExpressionChain.sameSource`),
	 * which collapses runs inside a literal, so `log("a  b", 1)` / `log("a b", 2)` read as
	 * "differ in one argument" and `--fix` emitted `log("a  b", if (c) 1 else 2);` — the else
	 * branch silently started passing a different string. Reduced from the shipped binary.
	 */
	public function testArgumentsDifferingInsideAStringLiteralAreNotShared(): Void {
		Assert.equals(
			0, violations(wrap('if (c) {\n\t\t\tlog("a  b", 1);\n\t\t} else {\n\t\t\tlog("a b", 2);\n\t\t}')).length,
			'two literals differing inside the quotes are two arguments, not one'
		);
		assertOneFinding(wrap('if (c) {\n\t\t\tlog("a  b", 1);\n\t\t} else {\n\t\t\tlog("a  b", 2);\n\t\t}'));
	}

	/** Run `fix` and re-emit through the canonical writer -- the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** Assert `src` yields exactly ONE finding, carrying this rule's id, severity and message. */
	private function assertOneFinding(src: String): Void {
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('join-branch-call', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('these branch calls differ in one argument and can be a single call with an if-expression argument', vs[0].message);
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new JoinBranchCall().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: JoinBranchCall = new JoinBranchCall();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
