package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.RedundantVoidReturn;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-void-return` check: a value-less `return;` as the last statement
 * of a function body is flagged `Info` and deleted by `--fix`. A `return;` that
 * guards the rest (inside an `if` / nested block) and a value `return e;` are left
 * alone.
 */
class RedundantVoidReturnCheckTest extends Test {

	public function testTrailingReturnFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('trace(1);\n\t\treturn;'));
		Assert.equals(1, vs.length);
		Assert.equals('redundant-void-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSoleReturnFlagged(): Void {
		Assert.equals(1, violations(wrap('return;')).length);
	}

	/** `return;` here exits early to skip the rest — it is not the body's last statement. */
	public function testReturnInIfGuardNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (c) return;\n\t\ttrace(1);')).length);
	}

	/** The `return;` is the last child of the `if` block, not of the function body. */
	public function testNestedTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (c) {\n\t\t\ttrace(1);\n\t\t\treturn;\n\t\t}')).length);
	}

	public function testValueReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}').length);
	}

	public function testFixDeletesReturn(): Void {
		final fixed: String = fixedSource(wrap('trace(1);\n\t\treturn;'));
		Assert.equals(-1, fixed.indexOf('return;'));
		Assert.isTrue(fixed.indexOf('trace(1);') >= 0);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-void-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-void-return'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + body + '\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantVoidReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: RedundantVoidReturn = new RedundantVoidReturn();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
