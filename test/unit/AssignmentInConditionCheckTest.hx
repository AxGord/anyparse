package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.AssignmentInCondition;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `assignment-in-condition` check: an assignment used as a condition
 * (`if (a = b)` / `while (a = b)` / `do … while (a = b)`) is flagged `Warning`,
 * report-only. A `==` comparison and an assignment in a branch body are not.
 */
class AssignmentInConditionCheckTest extends Test {

	public function testIfAssignFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (a = b) c();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('assignment-in-condition', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('assignment in a condition — did you mean ==?', vs[0].message);
	}

	public function testWhileAssignFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\twhile (a = b) c();\n\t}\n}').length);
	}

	public function testDoWhileAssignFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tdo c(); while (a = b);\n\t}\n}').length);
	}

	public function testParenthesizedAssignFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif ((a = b)) c();\n\t}\n}').length);
	}

	public function testEqualityNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a == b) c();\n\t}\n}').length);
	}

	public function testAssignInBranchBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (c) a = b;\n\t}\n}').length);
	}

	public function testReportOnlyNoFix(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a = b) c();\n\t}\n}';
		final check: AssignmentInCondition = new AssignmentInCondition();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(0, edits.length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('assignment-in-condition'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('assignment-in-condition'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { if (a = b) ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new AssignmentInCondition().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	public function testWhileExprAssignFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar x = while (a = b) r();\n\t}\n}').length);
	}

}
