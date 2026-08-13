package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.JoinBranchCall;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `join-branch-call` check: an `if / else if / … / else` chain whose every branch is the SAME
 * call differing in exactly one argument is flagged `Info`, and `fix` sinks the branching into that
 * argument -- `f(a, if (c1) x else if (c2) y else z)`. The 2-branch case is claimed too; the
 * ternary downgrade is `prefer-ternary-expression`'s, one `--fix` pass later.
 */
class JoinBranchCallCheckTest extends Test {

	public function testChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) log(1);\n\t\telse if (b) log(2);\n\t\telse log(3);'));
		Assert.equals(1, vs.length);
		Assert.equals('join-branch-call', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('these branch calls differ in one argument and can be a single call with an if-expression argument', vs[0].message);
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

	/** Run `fix` and re-emit through the canonical writer -- the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
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
