package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.SelfAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `self-assignment` check: a bare identifier assigned to itself (`x = x`) is
 * flagged `Warning`. A distinct assignment and a field self-assignment
 * (`this.x = this.x`, which may invoke a setter) are not. Report-only — `fix`
 * yields no edits.
 */
class SelfAssignmentCheckTest extends Test {

	public function testSelfAssignFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tx = x;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('self-assignment', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('this variable is assigned to itself', vs[0].message);
	}

	public function testDistinctAssignNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tx = y;\n\t}\n}').length);
	}

	public function testFieldSelfAssignNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tthis.x = this.x;\n\t}\n}').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tx = x;\n\t}\n}';
		final check: SelfAssignment = new SelfAssignment();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('self-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('self-assignment'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new SelfAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
