package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferBind;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-bind` check: a zero-parameter arrow lambda wrapping a single call with
 * arguments (`() -> f(a, b)`) is flagged `Info` and rewritten to `f.bind(a, b)`. A
 * parameter-bearing lambda, a block body, and a zero-argument call are not.
 */
class PreferBindCheckTest extends Test {

	public function testWrapperLambdaFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h(a, b);\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-bind', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testParamLambdaNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = x -> h(x);\n\t}\n}').length);
	}

	public function testParenParamLambdaNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = (x) -> h(x);\n\t}\n}').length);
	}

	public function testBlockBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> { h(a); };\n\t}\n}').length);
	}

	public function testZeroArgCallNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h();\n\t}\n}').length);
	}

	/** A `new X()` argument allocates — `.bind` would move the allocation to creation time; not flagged. */
	public function testAllocationArgNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h(new StringBuf());\n\t}\n}').length);
	}

	/** A call argument computes — `.bind` would evaluate it eagerly; not flagged. */
	public function testCallArgNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h(compute());\n\t}\n}').length);
	}

	/** An interpolated single-quoted string evaluates at bind time; not flagged. */
	public function testInterpolatedStringArgNotFlagged(): Void {
		Assert.equals(0, violations("class C {\n\tfunction f(x:Int):Void {\n\t\tvar g = () -> h('id-$x');\n\t}\n}").length);
	}

	/** An operator expression computes; not flagged. */
	public function testOperatorArgNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(a:Int):Void {\n\t\tvar g = () -> h(a + 1);\n\t}\n}').length);
	}

	/** Stable values — a plain string, a dotted constant chain, a negated literal — still convert. */
	public function testStableArgsFixed(): Void {
		final src: String = "class C {\n\tfunction f(i:Int):Void {\n\t\tvar g = () -> h(i, MouseEvent.CLICK, -1, 'plain');\n\t}\n}";
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals("h.bind(i, MouseEvent.CLICK, -1, 'plain')", edits[0].text);
	}

	public function testFixToBind(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar g = () -> h(a, b);\n\t}\n}';
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('h.bind(a, b)', edits[0].text);
	}

	public function testFixFieldAccessCallee(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar g = () -> obj.m(x);\n\t}\n}';
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('obj.m.bind(x)', edits[0].text);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-bind'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-bind'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { var g = () -> h(a, ').length);
	}

	public function testNestedLambdaFlaggedOnce(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h(() -> k(1));\n\t}\n}').length);
	}

	public function testGenericCallNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> fn<Int>(x);\n\t}\n}').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferBind().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
