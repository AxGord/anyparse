package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.RedundantParens;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-parens` check: a parenthesized expression wrapped directly in
 * another (`((e))`) is flagged `Info`. A lone `(e)` and a meaningful `(a + b)`
 * are not. `fix` unwraps the redundant layers to a single pair.
 */
class RedundantParensCheckTest extends Test {

	public function testDoubleParensFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar b = ((a));\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-parens', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('redundant parentheses', vs[0].message);
	}

	public function testTripleParensFlaggedOnce(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = (((a)));\n\t}\n}').length);
	}

	public function testSingleParenNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = (a);\n\t}\n}').length);
	}

	public function testMeaningfulParenNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = (a + c);\n\t}\n}').length);
	}

	public function testFixUnwrapsToSinglePair(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar b = (((a)));\n\t}\n}';
		final check: RedundantParens = new RedundantParens();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('(a)', edits[0].text);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-parens'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-parens'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantParens().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
