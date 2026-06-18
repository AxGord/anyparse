package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferTernaryReturn;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-ternary-return` check: an `if (cond) return a;` immediately
 * followed by a `return b;` is flagged `Info` and `fix` collapses the pair to
 * `return cond ? a : b;`. Only a no-else `if` that is a direct block statement
 * with a value-returning then-branch and an immediately-following value
 * `return` qualifies; the condition is parenthesised only when it binds no
 * tighter than `?:`.
 */
class PreferTernaryReturnCheckTest extends Test {

	public function testBasicPairFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-ternary-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/return pair can be a single ternary return', vs[0].message);
	}

	public function testBracedThenFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t}\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testVoidReturnThenNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) return;\n\t\treturn;\n\t}\n}').length);
	}

	public function testVoidReturnNextNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn;\n\t}\n}').length);
	}

	public function testElsePresentNotFlagged(): Void {
		// An else makes this `redundant-else-after-return`'s job; once de-nested it
		// becomes the no-else form this check then collapses.
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse return 2;\n\t}\n}').length);
	}

	public function testStatementBetweenNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\tb();\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testThenNotReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) b();\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testNextNotReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) return 1;\n\t\tb();\n\t}\n}').length);
	}

	public function testInlineNonBlockIfNotFlagged(): Void {
		// The inner `if` is the un-braced body of the outer `if`; the trailing
		// `return` is a sibling of the OUTER statement, not the inner `if`.
		Assert.equals(
			0, violations('class C {\n\tfunction f():Int {\n\t\tif (outer)\n\t\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}').length
		);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return a ? 1 : 0;', es[0].text);
	}

	public function testFixBracedThen(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t}\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return a ? 1 : 0;', es[0].text);
	}

	public function testFixComparisonConditionNotWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (x > 0) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return x > 0 ? 1 : 0;', es[0].text);
	}

	public function testFixTernaryConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Bool {\n\t\tif (a ? b : c) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return (a ? b : c) ? 1 : 0;', es[0].text);
	}

	public function testFixAssignmentConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Bool {\n\t\tif (x = g()) return 1;\n\t\treturn 0;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return (x = g()) ? 1 : 0;', es[0].text);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-ternary-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-ternary-return'));
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTernaryReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTernaryReturn = new PreferTernaryReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
