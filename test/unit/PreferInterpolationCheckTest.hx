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
 * and rewritten to string interpolation — `'$x'` for a simple identifier, `'${expr}'` for
 * any other interpolation-safe expression. A non-`Std` receiver, a wrong arity, and an
 * argument whose source carries a quote (which `'${ … }'` cannot wrap safely) are left
 * alone. A nested `Std.string(Std.string(x))` is flagged once (outermost only).
 */
class PreferInterpolationCheckTest extends Test {

	public function testSimpleIdentFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('Std.string(x)'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-interpolation', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this Std.string() call can be string interpolation', vs[0].message);
	}

	public function testFieldAccessFlagged(): Void {
		Assert.equals(1, violations(wrap('Std.string(o.f)')).length);
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
		Assert.equals("'$x'", fixText(wrap('Std.string(x)')));
	}

	public function testFixFieldAccess(): Void {
		Assert.equals("'${o.f}'", fixText(wrap('Std.string(o.f)')));
	}

	public function testFixNested(): Void {
		Assert.equals("'${Std.string(x)}'", fixText(wrap('Std.string(Std.string(x))')));
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
