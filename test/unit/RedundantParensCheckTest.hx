package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.RedundantParens;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.query.RefactorSupport;

/**
 * The `redundant-parens` check. Two arms: a parenthesized expression wrapped
 * directly in another (`((e))`), flagged wherever it sits, and a lone `(e)` in a
 * DELIMITED position — one the surrounding construct bounds itself, where the parens
 * cannot affect the parse whatever they hold. `fix` unwraps to a single pair outside
 * a delimited position and to nothing inside it. An operand of a unary or binary
 * operator, a call's callee, an assignment's target, the `switch` subject and a
 * `case` guard are never delimited.
 */
class RedundantParensCheckTest extends Test {

	public function testDoubleParensFlagged(): Void {
		final vs: Array<Violation> = violations(inFn('var b = ((a));'));
		Assert.equals(1, vs.length);
		Assert.equals('redundant-parens', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('redundant parentheses', vs[0].message);
	}

	public function testTripleParensFlaggedOnce(): Void {
		Assert.equals(1, violations(inFn('var b = (((a)));')).length);
	}

	public function testDoubleParensOutsideDelimitedPositionUnwrapToSinglePair(): Void {
		Assert.equals(1, violations(inFn('var b = ((a)) + c;')).length);
		Assert.equals(inFn('var b = (a) + c;'), fixed(inFn('var b = ((a)) + c;')));
	}

	public function testTripleParensOutsideDelimitedPositionUnwrapToSinglePair(): Void {
		Assert.equals(inFn('var b = (a) + c;'), fixed(inFn('var b = (((a))) + c;')));
	}

	public function testFixUnwrapsToSinglePair(): Void {
		final src: String = inFn('var b = (((a))) + c;');
		final check: RedundantParens = new RedundantParens();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('(a)', edits[0].text);
	}

	public function testDoubleParensInDelimitedPositionCollapseFully(): Void {
		Assert.equals(1, violations(inFn('var b = ((a));')).length);
		Assert.equals(inFn('var b = a;'), fixed(inFn('var b = ((a));')));
	}

	public function testTripleParensInDelimitedPositionCollapseFully(): Void {
		Assert.equals(inFn('var b = a;'), fixed(inFn('var b = (((a)));')));
	}

	public function testVarInitializerFlagged(): Void {
		Assert.equals(1, violations(inFn('var b = (a);')).length);
		Assert.equals(inFn('var b = a;'), fixed(inFn('var b = (a);')));
		Assert.equals(inFn('var b = a + c;'), fixed(inFn('var b = (a + c);')));
	}

	public function testFinalInitializerFlagged(): Void {
		Assert.equals(inFn('final m = -1;'), fixed(inFn('final m = (-1);')));
		Assert.equals(inFn('final m = a + c;'), fixed(inFn('final m = (a + c);')));
	}

	public function testFieldInitializerFlagged(): Void {
		Assert.equals('class C {\n\tvar m = 1;\n\tfinal n = a + c;\n}', fixed('class C {\n\tvar m = (1);\n\tfinal n = (a + c);\n}'));
	}

	public function testAssignmentRightHandSideFlagged(): Void {
		Assert.equals(inFn('x = a;'), fixed(inFn('x = (a);')));
		Assert.equals(inFn('x = a + c;'), fixed(inFn('x = (a + c);')));
	}

	public function testCompoundAssignmentRightHandSideFlagged(): Void {
		Assert.equals(inFn('x += a;'), fixed(inFn('x += (a);')));
		Assert.equals(inFn('x ??= a + c;'), fixed(inFn('x ??= (a + c);')));
	}

	public function testReturnValueFlagged(): Void {
		Assert.equals(inFn('return a;'), fixed(inFn('return (a);')));
		Assert.equals(inFn('return a + c;'), fixed(inFn('return (a + c);')));
	}

	public function testExpressionBodyReturnValueFlagged(): Void {
		Assert.equals('class C {\n\tfunction g() return a + c;\n}', fixed('class C {\n\tfunction g() return (a + c);\n}'));
	}

	public function testCallArgumentFlagged(): Void {
		Assert.equals(inFn('g(a);'), fixed(inFn('g((a));')));
		Assert.equals(inFn('g(a + c, d);'), fixed(inFn('g((a + c), d);')));
	}

	public function testNewArgumentFlagged(): Void {
		Assert.equals(inFn('var q = new T(a);'), fixed(inFn('var q = new T((a));')));
		Assert.equals(inFn('var q = new T(a + c);'), fixed(inFn('var q = new T((a + c));')));
	}

	public function testArrayElementFlagged(): Void {
		Assert.equals(inFn('var arr = [a];'), fixed(inFn('var arr = [(a)];')));
		Assert.equals(inFn('var arr = [a + c, d];'), fixed(inFn('var arr = [(a + c), d];')));
	}

	public function testObjectFieldValueFlagged(): Void {
		Assert.equals(inFn('var o = {x: a};'), fixed(inFn('var o = {x: (a)};')));
		Assert.equals(inFn('var o = {x: a + c};'), fixed(inFn('var o = {x: (a + c)};')));
	}

	public function testIfConditionFlagged(): Void {
		Assert.equals(inFn('if (a) g();'), fixed(inFn('if ((a)) g();')));
		Assert.equals(inFn('if (a + c) g();'), fixed(inFn('if ((a + c)) g();')));
	}

	public function testWhileConditionFlagged(): Void {
		Assert.equals(inFn('while (a) g();'), fixed(inFn('while ((a)) g();')));
		Assert.equals(inFn('while (a + c) g();'), fixed(inFn('while ((a + c)) g();')));
	}

	public function testDoWhileConditionFlagged(): Void {
		Assert.equals(inFn('do g(); while (a);'), fixed(inFn('do g(); while ((a));')));
		Assert.equals(inFn('do g(); while (a + c);'), fixed(inFn('do g(); while ((a + c));')));
	}

	public function testCallCalleeNotFlagged(): Void {
		Assert.equals(0, violations(inFn('(g)(1);')).length);
	}

	public function testAssignmentTargetNotFlagged(): Void {
		Assert.equals(0, violations(inFn('(x) = 1;')).length);
	}

	public function testBinaryOperandNotFlagged(): Void {
		Assert.equals(0, violations(inFn('var b = (a + c) * d;')).length);
	}

	public function testSingleParenInOperandPositionNotFlagged(): Void {
		Assert.equals(0, violations(inFn('var b = (a) + c;')).length);
	}

	public function testUnaryOperandNotFlagged(): Void {
		Assert.equals(0, violations(inFn('var b = -(a + c);')).length);
	}

	public function testIfExpressionBranchesNotFlagged(): Void {
		Assert.equals(1, violations(inFn('var s = if ((c)) (a) else (b);')).length);
		Assert.equals(inFn('var s = if (c) (a) else (b);'), fixed(inFn('var s = if ((c)) (a) else (b);')));
	}

	public function testTernaryConditionComparisonFlagged(): Void {
		final vs: Array<Violation> = violations(inFn('x = (a < b) ? 1 : -1;'));
		Assert.equals(1, vs.length);
		Assert.equals('redundant-parens', vs[0].rule);
		Assert.equals(inFn('x = a < b ? 1 : -1;'), fixed(inFn('x = (a < b) ? 1 : -1;')));
	}

	public function testTernaryConditionBooleanAndNullCoalFlagged(): Void {
		Assert.equals(inFn('x = a && b ? c : d;'), fixed(inFn('x = (a && b) ? c : d;')));
		Assert.equals(inFn('x = a ?? b ? c : d;'), fixed(inFn('x = (a ?? b) ? c : d;')));
	}

	public function testTernaryConditionPrimaryFlagged(): Void {
		Assert.equals(inFn('x = flag ? c : d;'), fixed(inFn('x = (flag) ? c : d;')));
		Assert.equals(inFn('x = obj.check() ? c : d;'), fixed(inFn('x = (obj.check()) ? c : d;')));
	}

	public function testTernaryConditionDoubleParensCollapseFully(): Void {
		Assert.equals(inFn('x = a < b ? c : d;'), fixed(inFn('x = ((a < b)) ? c : d;')));
	}

	public function testTernaryConditionIdempotent(): Void {
		final once: String = fixed(inFn('x = (a < b) ? 1 : -1;'));
		Assert.equals(once, fixed(once));
	}

	public function testTernaryConditionAssignmentKeepsParens(): Void {
		Assert.equals(0, violations(inFn('x = (a = b) ? c : d;')).length);
	}

	public function testTernaryConditionNestedTernaryKeepsParens(): Void {
		Assert.equals(0, violations(inFn('x = (a ? b : c) ? d : e;')).length);
	}

	public function testTernaryConditionRightGreedyKeepsParens(): Void {
		Assert.equals(0, violations(inFn('x = (untyped a) ? c : d;')).length);
		Assert.equals(0, violations(inFn('x = (a -> b) ? c : d;')).length);
		Assert.equals(0, violations(inFn('x = (@:meta a) ? c : d;')).length);
	}

	public function testTernaryBranchesNotFlagged(): Void {
		Assert.equals(0, violations(inFn('x = c ? (a) : (b);')).length);
	}

	public function testSwitchSubjectNotFlagged(): Void {
		Assert.equals(0, violations(inFn('switch ((v)) {\n\t\t\tcase _:\n\t\t}')).length);
	}

	public function testCaseGuardNotFlagged(): Void {
		Assert.equals(0, violations(inFn('switch v {\n\t\t\tcase X if (g): t();\n\t\t\tcase _:\n\t\t}')).length);
	}

	public function testMapLiteralArrowOperandsNotFlagged(): Void {
		Assert.equals(0, violations(inFn('var m = [(a) => (b)];')).length);
	}

	public function testMacroQuotedDeclarationKeepsItsParens(): Void {
		Assert.equals(0, violations(inFn('g((macro final w = 1), x);')).length);
		Assert.equals(0, violations(inFn('var b = [(macro var w = 1), x];')).length);
		Assert.equals(0, violations(inFn('var b = (macro final w = 1);')).length);
	}

	/**
	 * The greedy construct reached through a wrapper that is NOT the sole child — the
	 * shape a single-child spine walk misses. Each of these compiles as written and is
	 * rejected by the compiler once the parens are dropped.
	 */
	public function testGreedyBehindMultiChildWrapperKeepsItsParens(): Void {
		Assert.equals(0, violations(inFn('g((@:m macro final w = 1), 5);')).length);
		Assert.equals(0, violations(inFn('g((true ? macro 2 : macro final w = 1), 5);')).length);
		Assert.equals(0, violations(inFn('g((if (true) macro 2 else macro final w = 1), 5);')).length);
		Assert.equals(0, violations(inFn('g((macro 1 + macro final w = 1), 5);')).length);
		Assert.equals(0, violations(inFn('g((untyped macro final w = 1), 5);')).length);
		Assert.equals(0, violations(inFn('h({k: (@:m macro final w = 1), j: 2});')).length);
	}

	/**
	 * A greedy construct that a bracket of its own already closes is NOT greedy — the
	 * host's `)` / `]` / `}` bounds it, so the outer parens are removable. Pins the
	 * ends-together half of the walk against a bare last-child descent.
	 */
	public function testGreedyClosedByItsOwnBracketIsUnwrapped(): Void {
		Assert.equals(inFn('g(q(macro final w = 1), 5);'), fixed(inFn('g((q(macro final w = 1)), 5);')));
		Assert.equals(inFn('g([macro final w = 1], 5);'), fixed(inFn('g(([macro final w = 1]), 5);')));
		Assert.equals(inFn('g({k: macro final w = 1}, 5);'), fixed(inFn('g(({k: macro final w = 1}), 5);')));
	}

	/**
	 * `$a{…}` splices into the surrounding argument / element list only when nothing
	 * wraps it, so dropping the paren changes the built call's ARITY with no syntax
	 * error. Only a SPLICING host is affected.
	 */
	public function testSpliceReificationKeepsItsParensInASplicingHost(): Void {
		Assert.equals(0, violations(inFn("var a = macro g(($a{args}));")).length);
		Assert.equals(0, violations(inFn("var a = macro [($a{args})];")).length);
		Assert.equals(0, violations(inFn("var a = macro new T(($a{args}));")).length);
	}

	public function testSpliceReificationOutsideASplicingHostIsUnwrapped(): Void {
		// An object-literal field value never splices, so the splicing-host gate does
		// not apply and the ordinary delimited-slot rule unwraps it.
		Assert.equals(inFn("var a = macro h({k: $a{args}});"), fixed(inFn("var a = macro h({k: ($a{args})});")));
		Assert.equals(inFn("var a = macro q({k: $a{args}, j: 2});"), fixed(inFn("var a = macro q({k: ($a{args}), j: 2});")));
	}

	public function testDoubleParensAroundASpliceCollapseToOnePair(): Void {
		Assert.equals(inFn("var a = macro g(($a{args}));"), fixed(inFn("var a = macro g((($a{args})));")));
	}

	/** A drop that would weld the content onto a preceding keyword keeps a separating space. */
	public function testUnwrapKeepsASeparatorAfterAKeyword(): Void {
		Assert.equals(inFn('return a;'), fixed(inFn('return(a);')));
		Assert.equals(inFn('return a + c;'), fixed(inFn('return(a + c);')));
	}

	public function testDeclarationExpressionKeepsItsParens(): Void {
		Assert.equals(0, violations(inFn('g((var w = 1), x);')).length);
	}

	public function testMacroQuotedNonDeclarationIsStillUnwrapped(): Void {
		Assert.equals(inFn('g(macro 1, x);'), fixed(inFn('g((macro 1), x);')));
		Assert.equals(inFn('g(macro { var w = 1; }, x);'), fixed(inFn('g((macro { var w = 1; }), x);')));
	}

	public function testDoubleParensAroundMacroDeclarationCollapseToOnePair(): Void {
		Assert.equals(1, violations(inFn('g(((macro final w = 1)), x);')).length);
		Assert.equals(inFn('g((macro final w = 1), x);'), fixed(inFn('g(((macro final w = 1)), x);')));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-parens'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-parens'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantParens().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `src` with every edit the check's own `fix` produces applied. */
	private function fixed(src: String): String {
		final check: RedundantParens = new RedundantParens();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return RefactorSupport.applyEdits(src, check.fix(src, vs, plugin));
	}

	/** `body` as the sole statement of a method — the shortest host for a statement-level fixture. */
	private static inline function inFn(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

}
