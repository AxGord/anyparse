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

	/** A typed local declaration pins the element type — the `new Array()` is rewritten to `[]`. */
	public function testFixTypedArray(): Void {
		Assert.equals('[]', fixText('class C { function f():Void { var xs:Array<Int> = new Array(); } }'));
	}

	/** A typed field default pins the element type — rewritten to `[]`. */
	public function testFixTypedField(): Void {
		Assert.equals('[]', fixText('class C { public var xs:Array<Int> = new Array(); }'));
	}

	/** An unannotated local is NOT pinned — reported but left a finding, no edit (the gate is conservative). */
	public function testGateRefusesUntypedLocal(): Void {
		assertGateRefuses('class C { function f():Void { var xs = new Array(); } }');
	}

	/** An unannotated local whose only type source is the constructor `<Int>` is NOT pinned — `[]` would drop `<Int>`. */
	public function testGateRefusesUntypedTypeParam(): Void {
		assertGateRefuses('class C { function f():Void { var xs = new Array<Int>(); } }');
	}

	/** An argument-position `new Array()` is pinned by the callee, not the typed local — no edit. */
	public function testGateRefusesArgPosition(): Void {
		assertGateRefuses(
			'class C { function f():Void { var xs:Array<Int> = take(new Array()); } function take(a:Array<Int>):Array<Int> { return a; } }'
		);
	}

	/** A return-position `new Array()` is not a declaration initializer — no edit. */
	public function testGateRefusesReturnPosition(): Void {
		assertGateRefuses('class C { function f():Array<Int> { return new Array(); } }');
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

	/** Assert `src` is reported (one finding) yet gate-refused (no fix edit). */
	private function assertGateRefuses(src: String): Void {
		Assert.equals(1, violations(src).length);
		Assert.equals('<0 edits>', fixText(src));
	}

}
