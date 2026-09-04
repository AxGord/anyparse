package unit.check;

import anyparse.check.AsymmetricBranchBraces;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `asymmetric-branch-braces` check: an `if` / `else` pair with EXACTLY ONE braced branch,
 * reported `Info` and never fixed.
 *
 * It is the report-only twin of the writer's `singleStatementBraces: "symmetric"` policy, and it
 * carries the SAME two exemptions for the same reason - an `else if` link and an `else switch`
 * are keyword-headed else bodies that already close on a `}` of their own, and bracing the first
 * would rebuild the `else { if … }` shape `collapsible-else-if` exists to remove. The exemption
 * is ELSE-side only, which `testASwitchInThenPositionIsStillFlagged` pins: a `switch` opposite a
 * braced `else` is a genuine asymmetry.
 *
 * `DefaultOff` and `NoAutofix` are both asserted, not assumed: which way to resolve the
 * asymmetry is the project's taste, so the check may neither fire unasked nor rewrite.
 */
@:nullSafety(Strict)
class AsymmetricBranchBracesCheckTest extends Test {

	public function testThenBracedElseBareIsFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tq();'));
		Assert.equals(1, vs.length);
		Assert.equals('asymmetric-branch-braces', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('the then branch is braced and the else branch is not - brace both or neither', vs[0].message);
	}

	public function testThenBareElseBracedIsFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a)\n\t\t\tp();\n\t\telse {\n\t\t\tq();\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('the else branch is braced and the then branch is not - brace both or neither', vs[0].message);
	}

	public function testBothBracedIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else {\n\t\t\tq();\n\t\t}')).length);
	}

	public function testBothBareIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a)\n\t\t\tp();\n\t\telse\n\t\t\tq();')).length);
	}

	/** No else at all: nothing to be symmetric with. Pony's `if (d.length != 4) throw …;` shape. */
	public function testAnIfWithNoElseIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (d.length != 4)\n\t\t\tthrow \'bad\';')).length);
	}

	public function testAnElseIfLinkIsExempt(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b)\n\t\t\tq();')).length);
	}

	public function testAnElseSwitchIsExempt(): Void {
		Assert.equals(
			0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\tq();\n\t\t\t}')).length
		);
	}

	/** The exemption is ELSE-side only — a `switch` in THEN position is a real asymmetry. */
	public function testASwitchInThenPositionIsStillFlagged(): Void {
		Assert.equals(
			1, violations(wrap('if (a)\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\tp();\n\t\t\t}\n\t\telse {\n\t\t\tq();\n\t\t}')).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('asymmetric-branch-braces'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('asymmetric-branch-braces'));
	}

	/** Taste, not a defect: it may not fire unasked, and it may not rewrite. */
	public function testItIsOptInAndNeverFixes(): Void {
		final check: AsymmetricBranchBraces = new AsymmetricBranchBraces();
		Assert.isTrue((check: Dynamic) is DefaultOff, 'the check must be opt-in');
		Assert.isTrue((check: Dynamic) is NoAutofix, 'which way to resolve the asymmetry is the project\'s call');
	}

	private function violations(src: String): Array<Violation> {
		return new AsymmetricBranchBraces().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(a:Bool, b:Bool, d:String, s:String):Void {\n\t\t$body\n\t}\n}';
	}

}
