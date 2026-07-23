package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferIfExpressionAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `prefer-if-expression-assignment` check: an `if / else if / … / else` CHAIN whose
 * every branch assigns the same l-value with the same operator is flagged `Info`, and
 * `fix` collapses it to `lhs op if (c1) a else if (c2) b … else n;`. Disjoint from
 * `prefer-ternary-assignment` (which owns the 2-branch case): only a chain with at least
 * one `else if` terminating in a plain `else`, of single-statement same-l-value / same-op
 * assignments, qualifies. Unlike the ternary sibling a null-narrowing condition IS
 * flagged — the if-expression preserves the narrowing.
 */
class PreferIfExpressionAssignmentCheckTest extends Test {

	public function testBasicChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-if-expression-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/else-if assignment chain can be a single if-expression assignment', vs[0].message);
	}

	public function testFixThreeBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	public function testFixFourBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse if (c) x = 3;\n\t\telse x = 4;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) 2 else if (c) 3 else 4;', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) {\n\t\t\tx = 1;\n\t\t} else if (b) {\n\t\t\tx = 2;\n\t\t} else {\n\t\t\tx = 3;\n\t\t}'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	public function testFieldLvalueFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) button.x = p;\n\t\telse if (b) button.x = q;\n\t\telse button.x = r;'));
		Assert.equals(1, es.length);
		Assert.equals('button.x = if (a) p else if (b) q else r;', es[0].text);
	}

	/** A compound operator (`+=`) is excluded — collapsing it can break per-branch type unification. */
	public function testCompoundOperatorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x += 1;\n\t\telse if (b) x += 2;\n\t\telse x += 3;')).length);
	}

	/** A short-circuit `??=` is excluded — collapsing would skip the conditions when the l-value is non-null. */
	public function testNullCoalAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x ??= 1;\n\t\telse if (b) x ??= 2;\n\t\telse x ??= 3;')).length);
	}

	/** The 2-branch case is `prefer-ternary-assignment` territory, never this rule's. */
	public function testTwoBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse x = 2;')).length);
	}

	/** A chain with no terminal `else` has no value on the missing path — not collapsible. */
	public function testNoTerminalElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;')).length);
	}

	public function testDifferentLvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) y = 2;\n\t\telse x = 3;')).length);
	}

	public function testDifferentOperatorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) x += 2;\n\t\telse x = 3;')).length);
	}

	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tx = 1;\n\t\t\ty = 2;\n\t\t} else if (b) x = 2;\n\t\telse x = 3;')).length);
	}

	public function testNonAssignmentBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) g();\n\t\telse x = 3;')).length);
	}

	/** A comment in a dropped region (a non-head l-value) would be lost, so the chain is left unflagged. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) x = 1;\n\t\telse if (b) /* keep */ x = 2;\n\t\telse x = 3;')).length);
	}

	/**
	 * A null-narrowing guard condition IS flagged and collapsed — the if-expression keeps
	 * the verbatim `if (…)` condition, so the branch runs under the same narrowing (this is
	 * where the rule differs from `prefer-ternary-assignment`, which skips such conditions).
	 */
	public function testNullNarrowingChainFlagged(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (s != null && s.g()) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.equals(1, es.length);
		Assert.equals('x = if (s != null && s.g()) 1 else if (b) 2 else 3;', es[0].text);
	}

	/** A chain yields exactly ONE finding (the head), not one per `else if` link. */
	public function testChainFlaggedOnce(): Void {
		Assert.equals(1, violations(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse if (c) x = 3;\n\t\telse x = 4;')).length);
	}

	/** End-to-end through the canonical writer: the emitted file holds the collapsed assignment, valid Haxe (canonicalize re-parses it). */
	public function testFixOutputCollapsesChain(): Void {
		final out: String = applyFixOnce(wrap('if (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;'));
		Assert.isTrue(out.indexOf('x = if (a) 1 else if (b) 2 else 3;') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-if-expression-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-if-expression-assignment'));
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
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
		return new PreferIfExpressionAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferIfExpressionAssignment = new PreferIfExpressionAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
