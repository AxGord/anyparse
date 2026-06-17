package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferMapLiteral;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-map-literal` check: an empty-argument `new Map()` / `new Map<K, V>()` is
 * flagged `Info` and rewritten to `[]`. A non-Map construction and a `new Array()` are
 * left alone.
 */
class PreferMapLiteralCheckTest extends Test {

	public function testNewMapTypedFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('new Map<Int, Int>()'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-map-literal', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this new Map() can be the map literal []', vs[0].message);
	}

	public function testNewMapBareFlagged(): Void {
		Assert.equals(1, violations(wrap('new Map()')).length);
	}

	public function testArrayNotFlagged(): Void {
		Assert.equals(0, violations(wrap('new Array()')).length);
	}

	public function testOtherTypeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('new Foo()')).length);
	}

	public function testFixTypedMap(): Void {
		Assert.equals('[]', fixText(wrap('new Map<Int, Int>()')));
	}

	public function testFixBareMap(): Void {
		Assert.equals('[]', fixText(wrap('new Map()')));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-map-literal'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-map-literal'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = ' + expr + ';\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferMapLiteral().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixText(src: String): String {
		final check: PreferMapLiteral = new PreferMapLiteral();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length == 1 ? edits[0].text : '<' + edits.length + ' edits>';
	}

}
