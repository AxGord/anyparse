package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedParameter;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `unused-parameter` check: a function parameter never referenced in its
 * body is flagged `Info`. Used parameters, `_`-prefixed parameters, body-less
 * (interface / abstract) method declarations, and methods of a type carrying a
 * supertype clause (`extends` / `implements`, a contract candidate) are not
 * flagged. Local-function parameters are in scope. Report-only — `fix` yields no
 * edits (removing a parameter is a signature change for the `remove-param` op).
 */
class UnusedParameterCheckTest extends Test {

	public function testUnusedParameterFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('unused-parameter', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('unused parameter \'value\'', vs[0].message);
	}

	public function testUsedParameterNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(value:Int):Void {\n\t\tg(value);\n\t}\n}').length);
	}

	public function testUnderscorePrefixNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(_value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testImplementsContractNotFlagged(): Void {
		Assert.equals(0, violations('class C implements I {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testExtendsContractNotFlagged(): Void {
		Assert.equals(0, violations('class C extends B {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testInterfaceMethodNotFlagged(): Void {
		Assert.equals(0, violations('interface I {\n\tfunction f(value:Int):Void;\n}').length);
	}

	public function testLocalFunctionParameterFlagged(): Void {
		final vs: Array<Violation> =
			violations(
				'class C {\n\tpublic function m():Void {\n\t\tfunction inner(value:Int):Void {\n\t\t\tg();\n\t\t}\n\t\tinner(1);\n\t}\n}'
			);
		Assert.equals(1, vs.length);
		Assert.equals('unused parameter \'value\'', vs[0].message);
	}

	public function testParameterUsedInSiblingDefaultNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(a:Int, b:Int = a):Void {\n\t\tg(b);\n\t}\n}').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}';
		final check: UnusedParameter = new UnusedParameter();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unused-parameter'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unused-parameter'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(').length);
	}

	private function violations(src: String): Array<Violation> {
		return new UnusedParameter().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
