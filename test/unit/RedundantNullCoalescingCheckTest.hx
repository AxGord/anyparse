package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantNullCoalescing;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-null-coalescing` check: a `nonNull ?? fallback` whose left operand
 * is provably non-null makes the right operand dead. A nullable / optional / value-
 * unresolved / non-identifier left operand, or a nominal one without null-safety, is
 * not flagged. `fix` unwraps a flagged expression to its left operand.
 */
class RedundantNullCoalescingCheckTest extends Test {

	public function testValueTypeFlagged(): Void {
		Assert.equals(1, violations('class C { function f(x:Int) { var a = x ?? 0; } }').length);
	}

	public function testNominalUnderNullSafetyFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety class C { function f(x:Foo) { var a = x ?? other; } }').length);
	}

	public function testNullableNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety class C { function f(x:Null<Foo>) { var a = x ?? other; } }').length);
	}

	public function testOptionalParamNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety class C { function f(?x:Foo) { var a = x ?? other; } }').length);
	}

	public function testNominalWithoutNullSafetyNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(x:Foo) { var a = x ?? other; } }').length);
	}

	public function testUnannotatedOperandNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var v = g(); var a = v ?? 0; } function g():Int return 0; }').length);
	}

	public function testNonIdentLeftNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var a = g() ?? 0; } function g():Int return 0; }').length);
	}

	public function testFixUnwraps(): Void {
		final out: String = applyFix('class C { function f(x:Int) { var a = x ?? 0; } }');
		Assert.isTrue(out.indexOf('= x;') != -1, 'expected `= x;`, got: $out');
		Assert.isTrue(out.indexOf('??') == -1, 'the coalescing should be gone, got: $out');
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(x:Int) { var a = x ?? 0; } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-null-coalescing', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantNullCoalescing().run(
				[{ file: 'Bad.hx', source: 'class Bad { function f() { var a = x ??' }], new HaxeQueryPlugin()
			)
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-null-coalescing'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-null-coalescing'));
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantNullCoalescing().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: RedundantNullCoalescing = new RedundantNullCoalescing();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

}
