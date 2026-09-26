package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferBind;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `prefer-bind` check: a zero-parameter arrow lambda wrapping a single call with
 * arguments (`() -> f(a, b)`) is flagged `Info` and rewritten to `f.bind(a, b)`. A
 * parameter-bearing lambda, a block body, and a zero-argument call are not; nor is one whose
 * receiver or argument could read differently at creation than at the call — a written local, a
 * field, a nullable binding, a field receiver.
 */
class PreferBindCheckTest extends Test {

	public function testWrapperLambdaFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(a:Int, b:String):Void {\n\t\tvar g = () -> h(a, b);\n\t}\n}');
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

	/** Stable values — a parameter, a final local, a plain string, a negated literal — still convert. */
	public function testStableArgsFixed(): Void {
		final src: String =
			"class C {\n\tfunction f(i:Int):Void {\n\t\tfinal k:String = 'k';\n\t\tvar g = () -> h(i, k, -1, 'plain');\n\t}\n}";
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals("h.bind(i, k, -1, 'plain')", edits[0].text);
	}

	public function testFixToBind(): Void {
		final src: String = 'class C {\n\tfunction f(a:Int, b:String):Void {\n\t\tvar g = () -> h(a, b);\n\t}\n}';
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('h.bind(a, b)', edits[0].text);
	}

	public function testFixFieldAccessCallee(): Void {
		final src: String = 'class C {\n\tfunction f(obj:Obj, x:Int):Void {\n\t\tvar g = () -> obj.m(x);\n\t}\n}';
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('obj.m.bind(x)', edits[0].text);
	}

	/**
	 * `bind` reads its arguments when the callback is CREATED, the lambda when it is CALLED: a local
	 * written after the lambda exists would hand the callback a stale value.
	 */
	@:pin('control')
	@:killer('M-BIND-WRITES-IGNORED')
	public function testReassignedLocalNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tvar v:Int = 1;\n\t\tfinal g = () -> h(v);\n\t\tv = 2;\n\t}\n}').length
		);
		Assert.equals(0, violations('class C {\n\tfunction f(p:Int):Void {\n\t\tfinal g = () -> h(p);\n\t\tp++;\n\t}\n}').length);
	}

	/** A field — bare, through `this`, or a static — may change between creation and call. */
	@:pin('control')
	@:killer('M-BIND-FIELD-ARG')
	public function testFieldArgumentNotFlagged(): Void {
		final cls: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f():Void {\n\t\tfinal g = () -> h(ARG);\n\t}\n}';
		Assert.equals(0, violations(cls.replace('ARG', 'count')).length);
		Assert.equals(0, violations(cls.replace('ARG', 'this.count')).length);
		Assert.equals(0, violations(cls.replace('ARG', 'MouseEvent.CLICK')).length);
	}

	/**
	 * Null safety accepts a `Null<String>` capture passed on inside the lambda and rejects the same
	 * value as a `bind` argument (`Cannot assign nullable value here`); an optional parameter and a
	 * `null`-initialised local are nullable the same way.
	 */
	@:pin('control')
	@:killer('M-BIND-NULLABLE-ARG')
	public function testNullableArgumentNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tfunction f():Void {\n\t\tfinal d:Null<String> = Sys.getEnv('X');\n\t\tfinal g = () -> Sys.putEnv('K', d);\n"
				+ '\t}\n}'
			).length
		);
		Assert.equals(0, violations("class C {\n\tfunction f(?o:String):Void {\n\t\tfinal g = () -> Sys.putEnv('K', o);\n\t}\n}").length);
	}

	/** `bind` reads a field receiver at creation time, and throws there on a null one. */
	@:pin('control')
	@:killer('M-BIND-FIELD-RECEIVER')
	public function testFieldReceiverNotFlagged(): Void {
		final cls: String = 'class C {\n\tvar view:View;\n\tfunction f():Void {\n\t\tfinal g = () -> CALLEE(1);\n\t}\n}';
		Assert.equals(0, violations(cls.replace('CALLEE', 'view.m')).length);
		Assert.equals(0, violations(cls.replace('CALLEE', 'this.view.m')).length);
		Assert.equals(1, violations(cls.replace('CALLEE', 'this.m')).length);
		Assert.equals(1, violations(cls.replace('CALLEE', 'pkg.Type.m')).length);
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
