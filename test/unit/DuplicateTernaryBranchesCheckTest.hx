package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DuplicateTernaryBranches;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `duplicate-ternary-branches` check: a ternary whose branches are identical
 * (`cond ? x : x`) is flagged `Warning`. The autofix collapses it to the branch only
 * when the condition is side-effect-free; a side-effecting condition is report-only.
 */
class DuplicateTernaryBranchesCheckTest extends Test {

	public function testIdenticalBranchesFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar t = cond ? x : x;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('duplicate-ternary-branches', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('both branches of this ternary are identical', vs[0].message);
	}

	public function testDifferentBranchesNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar t = cond ? x : y;\n\t}\n}').length);
	}

	public function testFixCollapsesPureCondition(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar t = cond ? x : x;\n\t}\n}';
		final check: DuplicateTernaryBranches = new DuplicateTernaryBranches();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('x', edits[0].text);
	}

	public function testSideEffectingConditionReportedNotFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar t = g() ? x : x;\n\t}\n}';
		final check: DuplicateTernaryBranches = new DuplicateTernaryBranches();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, found.length);
		Assert.equals(0, check.fix(src, found, new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('duplicate-ternary-branches'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('duplicate-ternary-branches'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { var t = cond ? x : ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new DuplicateTernaryBranches().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
