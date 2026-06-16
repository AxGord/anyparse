package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ConstantCondition;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `constant-condition` check: a boolean literal used as an `if` condition
 * (`if (true)` / `if (false)`, statement or expression form) is flagged
 * `Warning`. A non-literal condition and a loop condition (`while (true)`, an
 * idiomatic infinite loop) are not. Report-only — `fix` yields no edits.
 */
class ConstantConditionCheckTest extends Test {

	public function testIfTrueFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (true) g();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('constant-condition', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('condition is always true', vs[0].message);
	}

	public function testIfFalseFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (false) g();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('condition is always false', vs[0].message);
	}

	public function testIfExprFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\treturn if (true) 1 else 2;\n\t}\n}').length);
	}

	public function testNonLiteralConditionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tif (x) g();\n\t}\n}').length);
	}

	public function testWhileTrueNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\twhile (true) g();\n\t}\n}').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (true) g();\n\t}\n}';
		final check: ConstantCondition = new ConstantCondition();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('constant-condition'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('constant-condition'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ConstantCondition().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
