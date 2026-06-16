package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.IdenticalOperands;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `identical-operands` check: a binary operator whose two operands are
 * textually identical (`a == a`, `a != a`, `a && a`, `a.b == a.b`) is flagged
 * `Warning`. Distinct operands and call-bearing operands (`g() == g()`) are not.
 * Report-only — `fix` yields no edits.
 */
class IdenticalOperandsCheckTest extends Test {

	public function testEqualOperandsFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar b = a == a;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('identical-operands', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('both operands of this operator are identical', vs[0].message);
	}

	public function testNotEqualOperandsFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = a != a;\n\t}\n}').length);
	}

	public function testLogicalAndIdenticalFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = a && a;\n\t}\n}').length);
	}

	public function testFieldAccessIdenticalFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = a.x == a.x;\n\t}\n}').length);
	}

	public function testDistinctOperandsNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = a == c;\n\t}\n}').length);
	}

	public function testCallOperandsNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = g() == g();\n\t}\n}').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar b = a == a;\n\t}\n}';
		final check: IdenticalOperands = new IdenticalOperands();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('identical-operands'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('identical-operands'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new IdenticalOperands().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
