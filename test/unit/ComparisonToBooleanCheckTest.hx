package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ComparisonToBoolean;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `comparison-to-boolean` check: a comparison against a boolean literal
 * (`x == true`, `x != false`, `true == x`) is flagged `Info`, report-only. An operand
 * reached through a null-safe access (`obj?.flag == true`) is SKIPPED — that `== true`
 * may be load-bearing on a `Null<Bool>` under strict null-safety.
 */
class ComparisonToBooleanCheckTest extends Test {

	public function testEqTrueFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar b = x == true;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('comparison-to-boolean', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('comparison against a boolean literal', vs[0].message);
	}

	public function testNeqFalseFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = x != false;\n\t}\n}').length);
	}

	public function testLiteralOnLeftFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = true == x;\n\t}\n}').length);
	}

	public function testBooleanExprOperandFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = (a > c) == true;\n\t}\n}').length);
	}

	public function testNullSafeOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj?.ready() == true;\n\t}\n}').length);
	}

	public function testNullSafeFieldSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj?.flag == false;\n\t}\n}').length);
	}

	public function testNoBooleanLiteralNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = x == c;\n\t}\n}').length);
	}

	public function testBothBooleanLiteralsNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = true == true;\n\t}\n}').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar b = x == true;\n\t}\n}';
		final check: ComparisonToBoolean = new ComparisonToBoolean();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('comparison-to-boolean'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('comparison-to-boolean'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ComparisonToBoolean().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
