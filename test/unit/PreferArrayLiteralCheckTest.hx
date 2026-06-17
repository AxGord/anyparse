package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferArrayLiteral;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-array-literal` check: an empty-argument `new Array()` / `new Array<T>()` is
 * flagged `Info` and rewritten to `[]`. A `new Array(x)` with an argument, a non-Array
 * construction, and a `new Map()` are left alone.
 */
class PreferArrayLiteralCheckTest extends Test {

	public function testNewArrayTypedFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('new Array<Int>()'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-array-literal', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this new Array() can be the array literal []', vs[0].message);
	}

	public function testNewArrayBareFlagged(): Void {
		Assert.equals(1, violations(wrap('new Array()')).length);
	}

	public function testMapNotFlagged(): Void {
		Assert.equals(0, violations(wrap('new Map()')).length);
	}

	public function testOtherTypeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('new Foo()')).length);
	}

	public function testArrayWithArgsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('new Array(x)')).length);
	}

	public function testFixTypedArray(): Void {
		Assert.equals('[]', fixText(wrap('new Array<Int>()')));
	}

	public function testFixBareArray(): Void {
		Assert.equals('[]', fixText(wrap('new Array()')));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-array-literal'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-array-literal'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = ' + expr + ';\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferArrayLiteral().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixText(src: String): String {
		final check: PreferArrayLiteral = new PreferArrayLiteral();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length == 1 ? edits[0].text : '<' + edits.length + ' edits>';
	}

}
