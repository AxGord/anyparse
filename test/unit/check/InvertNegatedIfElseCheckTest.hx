package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.InvertNegatedIfElse;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * The `invert-negated-if-else` check: an `if` STATEMENT with an `else` whose condition's
 * top-level node is a logical not (`if (!c) A else B`) is flagged `Info`. The autofix drops
 * the `!` and swaps the branches (`if (c) B else A`), a semantics-safe exact complement. A
 * no-`else` `if`, an else-if chain, a non-top-level `!`, and a condition-comment case are
 * not flagged.
 */
class InvertNegatedIfElseCheckTest extends Test {

	public function testNegatedIfElseFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('invert-negated-if-else', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this negated if-else can be inverted — drop the ! and swap the branches', vs[0].message);
	}

	public function testBracedIfElseFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) { p(); } else { q(); }\n\t}\n}').length);
	}

	public function testParenWrappedConditionFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif ((!a)) x(); else y();\n\t}\n}').length);
	}

	public function testNonNegatedNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) x(); else y();\n\t}\n}').length);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x();\n\t}\n}').length);
	}

	public function testElseIfChainNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else if (b) y(); else z();\n\t}\n}').length);
	}

	public function testTopLevelAndNotFlagged(): Void {
		// The `!` negates only `a`; the condition's top-level node is `&&`, not a not.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a && b) x(); else y();\n\t}\n}').length);
	}

	public function testNotEqualNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a != b) x(); else y();\n\t}\n}').length);
	}

	public function testConditionCommentNotFlagged(): Void {
		// A comment inside the condition would be dropped by the rebuilt condition, so skip.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!/* c */a) x(); else y();\n\t}\n}').length);
	}

	public function testFixInvertsAndSwaps(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}');
		Assert.equals(3, es.length);
		Assert.equals('a', es[0].text);
		Assert.equals('y();', es[1].text);
		Assert.equals('x();', es[2].text);
	}

	public function testFixUnwrapsOperandParen(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tif (!(a && b)) x(); else y();\n\t}\n}');
		Assert.equals('a && b', es[0].text);
	}

	public function testFixAppliedOutput(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (a) y(); else x();\n\t}\n}', CanonicalEdit.applyEdits(src, edits(src)));
	}

	public function testFixAppliedOutputBraced(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!a) { p(); } else { q(); }\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tif (a) { q(); } else { p(); }\n\t}\n}', CanonicalEdit.applyEdits(src, edits(src))
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('invert-negated-if-else'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('invert-negated-if-else'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** A comment INSIDE the kept operand travels with it, so the statement form is still inverted. */
	public function testStatementCommentInsideOperandTravels(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!(a /* k */ && b)) x(); else y();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (a /* k */ && b) y(); else x();\n\t}\n}', fixed(src));
	}

	public function testNegatedTernaryFlagged(): Void {
		final vs: Array<Violation> = violations(fn('final v = !a ? 1 : 2;'));
		Assert.equals(1, vs.length);
		Assert.equals('this negated ternary can be inverted — drop the ! and swap the branches', vs[0].message);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testNegatedTernaryFixed(): Void {
		Assert.equals(fn('final v = a ? 2 : 1;'), fixed(fn('final v = !a ? 1 : 2;')));
	}

	/** The TM shape the task came from (`ThumbnailReader`, anonymized): a call and a `null` swap places. */
	public function testNegatedTernaryReturnFixed(): Void {
		Assert.equals(fn('return d.has.t ? decode(d.node.t.data) : null;'), fixed(fn('return !d.has.t ? null : decode(d.node.t.data);')));
	}

	/** A redundant paren around the operand drops: `||` binds tighter than `?:`. */
	public function testNegatedTernaryOperandParenDrops(): Void {
		Assert.equals(fn('final v = a || b ? 2 : 1;'), fixed(fn('final v = !(a || b) ? 1 : 2;')));
	}

	/** An operand that binds LOOSER than `?:` keeps its paren — the parse round-trip decides. */
	public function testNegatedTernaryAssignmentOperandKeepsParen(): Void {
		Assert.equals(fn('final v = (a = b) ? 2 : 1;'), fixed(fn('final v = !(a = b) ? 1 : 2;')));
	}

	/** A ternary moved into the else slot of another reads as a chain link; parenthesised, it is a plain value and swaps. */
	public function testNegatedTernaryParenthesisedNestedBranchSwaps(): Void {
		Assert.equals(fn('final v = a ? 3 : (b ? 1 : 2);'), fixed(fn('final v = !a ? (b ? 1 : 2) : 3;')));
	}

	public function testTernaryChainNotFlagged(): Void {
		Assert.equals(0, violations(fn('final v = !a ? 1 : b ? 2 : 3;')).length);
		Assert.equals(0, violations(fn('final v = !a ? b ? 1 : 2 : 3;')).length);
	}

	/** Only a literal top-level `!`: a `!=`, and a `&&` whose operand is negated, keep their shape. */
	public function testTernaryNonTopLevelNotNotFlagged(): Void {
		Assert.equals(0, violations(fn('final v = a != b ? 1 : 2;')).length);
		Assert.equals(0, violations(fn('final v = !a && b ? 1 : 2;')).length);
		Assert.equals(0, violations(fn('final v = a ? 1 : 2;')).length);
	}

	/** A comment the positive condition would drop leaves the ternary report-only. */
	public function testTernaryConditionCommentReportOnly(): Void {
		final src: String = fn('final v = !/* c */a ? 1 : 2;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'this negated ternary can be inverted — drop the ! and swap the branches (a comment blocks the autofix)', vs[0].message
		);
		Assert.equals(0, edits(src).length);
	}

	/** A comment in the glue stays put while the branches move, so it would describe the other one: report-only. */
	public function testTernaryGlueCommentReportOnly(): Void {
		final src: String = fn('final v = !a ? /* one */ 1 : 2;');
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** A comment INSIDE a branch travels with it. */
	public function testTernaryBranchCommentTravels(): Void {
		Assert.equals(fn('final v = a ? 2 : f(/* one */ 1);'), fixed(fn('final v = !a ? f(/* one */ 1) : 2;')));
	}

	/** A report-only outer ternary is descended into: the inner one is rewritten. */
	public function testReportOnlyTernaryDescended(): Void {
		Assert.equals(fn('final v = !/* c */a ? (b ? 2 : 1) : 3;'), fixed(fn('final v = !/* c */a ? (!b ? 1 : 2) : 3;')));
	}

	/** A fixable outer ternary stops the walk: the inner one surfaces on the next pass. */
	public function testNestedNegatedTernaryOnePerPass(): Void {
		Assert.equals(1, violations(fn('final v = !a ? (!b ? 1 : 2) : 3;')).length);
	}

	public function testNegatedIfExpressionFixed(): Void {
		final src: String = fn('final v = if (!a) 1 else 2;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('this negated if-expression can be inverted — drop the ! and swap the branches', vs[0].message);
		Assert.equals(fn('final v = if (a) 2 else 1;'), fixed(src));
	}

	public function testIfExpressionElseIfChainNotFlagged(): Void {
		Assert.equals(0, violations(fn('final v = if (!a) 1 else if (b) 2 else 3;')).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new InvertNegatedIfElse(), src);
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: InvertNegatedIfElse = new InvertNegatedIfElse();
		return CheckFixture.edits(check, src);
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f():Int {\n\t\t$body\n\t}\n}';
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new InvertNegatedIfElse(), src);
	}

}
