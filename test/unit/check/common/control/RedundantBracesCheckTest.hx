package unit.check.common.control;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.common.control.AsymmetricBranchBraces;
import anyparse.check.common.control.RedundantBraces;

/**
 * The `redundant-braces` check: every branch of an if / else-if chain, or a loop body, holding one statement in braces
 * that do no work - reported `Info`, fixed by stripping the braces. The pins hold the four ways braces DO work: a
 * following `else` they keep off an inner `if`, a binding they scope, a terminator the statement lacks, a comment they
 * enclose - and the symmetry contract with `asymmetric-branch-braces`, which a mixed chain belongs to.
 */
@:nullSafety(Strict)
class RedundantBracesCheckTest extends Test {

	public function testAnAllBracedChainIsFlagged(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) {\n\t\t\tq();\n\t\t} else {\n\t\t\tr();\n\t\t}');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-braces', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('every branch of this if/else holds one statement in braces it does not need', vs[0].message);
		Assert.equals(src.indexOf('if (a)'), vs[0].span?.from);
		Assert.equals(wrap('if (a) p(); else if (b) q(); else r();'), fixed(src));
	}

	public function testAnIfWithNoElseIsFlagged(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t}');
		Assert.equals(1, violations(src).length);
		Assert.equals(wrap('if (a) p();'), fixed(src));
	}

	public function testALoopBodyIsFlagged(): Void {
		final src: String = wrap('for (c in s) {\n\t\t\tp();\n\t\t}\n\t\twhile (a) {\n\t\t\tq();\n\t\t}');
		final vs: Array<Violation> = violations(src);
		Assert.equals(2, vs.length);
		Assert.equals('this loop body holds one statement in braces it does not need', vs[0].message);
		Assert.equals(wrap('for (c in s) p();\n\t\twhile (a) q();'), fixed(src));
	}

	public function testADoWhileBodyIsNotRead(): Void {
		Assert.equals(0, violations(wrap('do {\n\t\t\tp();\n\t\t} while (a);')).length);
	}

	/** A block of two statements, a lone `if` (the collapsible rules' shape) and a nested block keep their braces. */
	public function testKeptShapesAreNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t}')).length);
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tif (b) p();\n\t\t}')).length);
		Assert.equals(0, violations(wrap('for (c in s) {\n\t\t\t{\n\t\t\t\tp();\n\t\t\t}\n\t\t}')).length);
		Assert.equals(0, violations(wrap('while (a) {\n\t\t\t#if x\n\t\t\tp();\n\t\t\t#end\n\t\t}')).length);
	}

	/**
	 * The dangling else: the braces close the loop that holds an else-less `if`, so the trailing `else r();` binds to
	 * `if (a)`. Stripped, it would bind to `if (d)`. Where no `else` can follow - a statement of a block - the same body
	 * goes bare.
	 */
	@:pin('control')
	@:killer('M-REDUNDANT-BRACES-DANGLING-ELSE')
	public function testBracesKeepingAnElseOffAnInnerIfStay(): Void {
		Assert.equals(0, violations(wrap('if (a) for (c in s) {\n\t\t\twhile (b) if (d) p();\n\t\t} else r();')).length);
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tfor (c in s) if (d) p();\n\t\t} else {\n\t\t\tr();\n\t\t}')).length);
		final safe: String = wrap('for (c in s) {\n\t\t\twhile (b) if (d) p();\n\t\t}');
		Assert.equals(1, violations(safe).length, 'nothing can follow a statement of a block');
		Assert.equals(wrap('for (c in s) while (b) if (d) p();'), fixed(safe));
	}

	/** A declaration keeps its braces: they scope the binding. */
	@:pin('control')
	@:killer('M-REDUNDANT-BRACES-DECL')
	public function testADeclarationKeepsItsBraces(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tvar x = 1;\n\t\t}')).length);
		Assert.equals(0, violations(wrap('for (c in s) {\n\t\t\tfunction g() {}\n\t\t}')).length);
	}

	/** A statement with no terminator of its own would run into what follows it. */
	@:pin('control')
	@:killer('M-ASYM-FIX-UNTERMINATED')
	public function testAnUnterminatedStatementKeepsItsBraces(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp()\n\t\t} else {\n\t\t\tq();\n\t\t}')).length);
	}

	/** A comment between a brace and the statement is the braces' content too. */
	@:pin('control')
	@:killer('M-REDUNDANT-BRACES-COMMENT')
	public function testACommentInsideTheBracesKeepsThem(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\t// why\n\t\t\tp();\n\t\t}')).length);
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp(); // why\n\t\t} else {\n\t\t\tq();\n\t\t}')).length);
	}

	/**
	 * A chain is stripped whole or not at all: a branch that must stay braced keeps its siblings braced, and a chain
	 * that is already mixed is `asymmetric-branch-braces`'s. Stripping a chain never leaves that rule a finding.
	 */
	@:pin('control')
	@:killer('M-REDUNDANT-BRACES-ASYMMETRIC')
	public function testAChainIsStrippedWholeOrNotAtAll(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else {\n\t\t\tq();\n\t\t\tr();\n\t\t}')).length);
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tq();')).length);
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) {\n\t\t\tq();\n\t\t} else {\n\t\t\tr();\n\t\t}');
		Assert.equals(0, CheckFixture.violations(new AsymmetricBranchBraces(), fixed(src)).length);
	}

	/** An `else switch` is neither braced nor bare: the chain's braced branches still go. */
	public function testAnElseSwitchIsNeutral(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else switch s {\n\t\t\tcase _:\n\t\t\t\tr();\n\t\t}');
		Assert.equals(1, violations(src).length);
		Assert.equals(wrap('if (a) p(); else switch s {\n\t\t\tcase _:\n\t\t\t\tr();\n\t\t}'), fixed(src));
		Assert.equals(0, CheckFixture.violations(new AsymmetricBranchBraces(), fixed(src)).length);
	}

	public function testTheCheckIsDefaultOff(): Void {
		Assert.isTrue(Std.isOfType(new RedundantBraces(), DefaultOff));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new RedundantBraces(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new RedundantBraces(), src);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(a:Bool, b:Bool, d:Bool, s:Array<Int>):Void {\n\t\t$body\n\t}\n}';
	}

}
