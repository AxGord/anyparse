package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFinal;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-final` check: a local `var` never reassigned is flagged `Info` and
 * `var` is rewritten to `final`. A reassigned `var` (`=` / `+=` / `++`), a no-init
 * or multi-declaration `var`, and a never-read `var` (`unused-local`'s domain) are
 * left alone. Write detection is scope-resolved and complete, so the autofix is
 * always sound.
 */
class PreferFinalCheckTest extends Test {

	public function testNeverReassignedFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var x = 0;\n\t\ttrace(x);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-final', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('local \'x\' is never reassigned; use final', vs[0].message);
	}

	public function testPlainAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x = 0;\n\t\tx = 1;\n\t\ttrace(x);')).length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x = 0;\n\t\tx += 1;\n\t\ttrace(x);')).length);
	}

	public function testIncrementNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x = 0;\n\t\tx++;\n\t\ttrace(x);')).length);
	}

	public function testNoInitNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:Int;\n\t\tx = 5;\n\t\ttrace(x);')).length);
	}

	/** A second var in the body is reassigned, but the candidate is not — only the candidate matters. */
	public function testWriteToOtherVarStillFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var x = 0;\n\t\tvar y = 0;\n\t\ty = 1;\n\t\ttrace(x + y);'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf("'x'") >= 0);
	}

	/** `var a = 1, b = 2` projects as one node with two children — the children-count guard skips it. */
	public function testMultiVarBothInitNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a = 1, b = 2;\n\t\ttrace(a + b);')).length);
	}

	/**
	 * `var a, b = 2` collapses to a single node named `a` with one child — AST-
	 * indistinguishable from a real single var. The top-level-comma guard is what
	 * skips it; `a` is referenced so the read gate alone would not.
	 */
	public function testMultiVarPartialInitNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a, b = 2;\n\t\ttrace(a + b);')).length);
	}

	/** Never read: `unused-local`'s domain. The read gate keeps the two checks from overlapping. */
	public function testNeverReadNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x = compute();')).length);
	}

	/** A use only through `'$x'` interpolation still counts — the text read gate catches it. */
	public function testInterpolationReadFlagged(): Void {
		Assert.equals(1, violations("class C {\n\tfunction f():Void {\n\t\tvar x = 1;\n\t\ttrace('$x');\n\t}\n}").length);
	}

	/** A comma inside a string initializer is not a declaration separator. */
	public function testStringInitWithCommaFlagged(): Void {
		Assert.equals(1, violations(wrap('var x = "a, b";\n\t\ttrace(x);')).length);
	}

	/** A comma inside `[]` is not a declaration separator. */
	public function testArrayInitWithCommaFlagged(): Void {
		Assert.equals(1, violations(wrap('var x = [1, 2];\n\t\ttrace(x[0]);')).length);
	}

	/** A comma inside a call's `()` is not a declaration separator. */
	public function testCallInitWithCommaFlagged(): Void {
		Assert.equals(1, violations(wrap('var x = g(1, 2);\n\t\ttrace(x);')).length);
	}

	/**
	 * Conservative limitation: a generic type-parameter comma (`Map<Int, String>`)
	 * reads as top-level because `<>` is not tracked, so the var is skipped rather
	 * than risk a wrong fix. Pinned so the trade-off is intentional, not accidental.
	 */
	public function testGenericTypedVarConservativelySkipped(): Void {
		Assert.equals(0, violations(wrap('var x:Map<Int, String> = m;\n\t\ttrace(x);')).length);
	}

	public function testFixVarToFinal(): Void {
		final fixed: String = fixedSource(wrap('var x = 0;\n\t\ttrace(x);'));
		Assert.isTrue(fixed.indexOf('final x = 0') >= 0);
		Assert.equals(-1, fixed.indexOf('var x = 0'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-final'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-final'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + body + '\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferFinal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: PreferFinal = new PreferFinal();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
