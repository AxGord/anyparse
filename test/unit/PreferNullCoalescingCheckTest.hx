package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferNullCoalescing;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-null-coalescing` check: a null-guard ternary in any of the four shapes
 * (`x != null ? x : y`, `null != x ? x : y`, `x == null ? y : x`, `null == x ? y : x`)
 * is flagged `Info` and rewritten to `x ?? y`. A call-bearing guarded value, a
 * wrong-side branch, and a plain ternary are left alone. A bare ternary fallback is
 * parenthesized in the rewrite (`??` binds tighter than `?:`).
 */
class PreferNullCoalescingCheckTest extends Test {

	public function testNotEqShapeFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('a != null ? a : b'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-null-coalescing', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this null-guard ternary can be the null-coalescing operator (??)', vs[0].message);
	}

	public function testNullNotEqShapeFlagged(): Void {
		Assert.equals(1, violations(wrap('null != a ? a : b')).length);
	}

	public function testEqShapeFlagged(): Void {
		Assert.equals(1, violations(wrap('a == null ? b : a')).length);
	}

	public function testNullEqShapeFlagged(): Void {
		Assert.equals(1, violations(wrap('null == a ? b : a')).length);
	}

	public function testCallGuardedNotFlagged(): Void {
		Assert.equals(0, violations(wrap('f() != null ? f() : g()')).length);
	}

	public function testWrongSideBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('a != null ? b : a')).length);
	}

	public function testPlainTernaryNotFlagged(): Void {
		Assert.equals(0, violations(wrap('cond ? a : b')).length);
	}

	public function testFixNotEqShape(): Void {
		Assert.equals('a ?? b', fixText(wrap('a != null ? a : b')));
	}

	public function testFixEqShape(): Void {
		Assert.equals('a ?? b', fixText(wrap('a == null ? b : a')));
	}

	public function testFixFieldOperand(): Void {
		Assert.equals('o.f ?? d', fixText(wrap('o.f != null ? o.f : d')));
	}

	public function testFixNestedFallbackParenthesized(): Void {
		Assert.equals('a ?? (b != null ? b : c)', fixText(wrap('a != null ? a : b != null ? b : c')));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-null-coalescing'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-null-coalescing'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testIncrementGuardedNotFlagged(): Void {
		Assert.equals(0, violations(wrap('i++ != null ? i++ : y')).length);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = ' + expr + ';\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferNullCoalescing().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixText(src: String): String {
		final check: PreferNullCoalescing = new PreferNullCoalescing();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length == 1 ? edits[0].text : '<' + edits.length + ' edits>';
	}

}
