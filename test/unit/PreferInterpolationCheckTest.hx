package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferInterpolation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-interpolation` check: a single-argument `Std.string(x)` is flagged `Info`
 * and rewritten to string interpolation — `'$x'` for a simple identifier whose declared
 * type is provably not itself nullable, `'${expr}'` for any other interpolation-safe
 * expression. A non-`Std` receiver, a wrong arity, and an argument whose source carries a
 * quote (which `'${ … }'` cannot wrap safely) are left alone. A nested
 * `Std.string(Std.string(x))` is flagged once (outermost only).
 *
 * `Std.string` accepts a nullable value; the interpolation form does not under
 * `@:nullSafety(Strict)` (field access never narrows), so a bare field-access argument
 * (`Std.string(o.f)`) is left alone unconditionally — see the `testFieldAccess*` /
 * `testUnannotatedLocalNotFlagged` / `testNullTypedLocalNotFlagged` /
 * `testDynamicTypedLocalNotFlagged` / `test*ParamNotFlagged` gate tests below.
 */
class PreferInterpolationCheckTest extends Test {

	public function testSimpleIdentFlagged(): Void {
		final vs: Array<Violation> = violations(body('var name: Int = 1;\n\t\tvar y = Std.string(name);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-interpolation', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this Std.string() call can be string interpolation', vs[0].message);
	}

	public function testFieldAccessNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Std.string(o.f)')).length);
	}

	public function testNonStdReceiverNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Foo.string(x)')).length);
	}

	public function testWrongArityNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Std.string(a, b)')).length);
	}

	public function testQuoteArgNotFlagged(): Void {
		Assert.equals(0, violations(wrap("Std.string(c == 'a')")).length);
	}

	public function testNestedFlaggedOnce(): Void {
		Assert.equals(1, violations(wrap('Std.string(Std.string(x))')).length);
	}

	public function testFixSimpleIdent(): Void {
		Assert.equals("'$name'", fixText(body('var name: Int = 1;\n\t\tvar y = Std.string(name);')));
	}

	public function testFixFieldAccessNoEdit(): Void {
		Assert.equals('<0 edits>', fixText(wrap('Std.string(o.f)')));
	}

	public function testFixNested(): Void {
		Assert.equals("'${Std.string(x)}'", fixText(wrap('Std.string(Std.string(x))')));
	}

	public function testFieldAccessInNullCheckedBranchNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(obj: Holder):Void {\n\t\tif (obj.field != null) {\n\t\t\tvar s: String = Std.string(obj.field);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNullTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var n: Null<Int> = null;\n\t\tvar s: String = Std.string(n);')).length);
	}

	public function testDynamicTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var d: Dynamic = 1;\n\t\tvar s: String = Std.string(d);')).length);
	}

	public function testOptionalParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(?p: Int):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDefaultNullParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(p: Int = null):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testUnannotatedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var u = make();\n\t\tvar s: String = Std.string(u);')).length);
	}

	public function testNonNullLocalStillFlagged(): Void {
		final vs: Array<Violation> = violations(body('var localNonNull: Int = 1;\n\t\tvar s: String = Std.string(localNonNull);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-interpolation', vs[0].rule);
	}

	public function testFixNonNullLocal(): Void {
		Assert.equals("'$localNonNull'", fixText(body('var localNonNull: Int = 1;\n\t\tvar s: String = Std.string(localNonNull);')));
	}

	public function testNonNullParamStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(p: Int):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testStringTypedLocalStillFlagged(): Void {
		Assert.equals(1, violations(body('var s: String = "a";\n\t\tvar r: String = Std.string(s);')).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-interpolation'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-interpolation'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = ' + expr + ';\n\t}\n}';
	}

	/** A class fixture whose method body is `stmts` — for gate tests that declare their own typed locals. */
	private function body(stmts: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + stmts + '\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferInterpolation().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixText(src: String): String {
		final check: PreferInterpolation = new PreferInterpolation();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length == 1 ? edits[0].text : '<' + edits.length + ' edits>';
	}

}
