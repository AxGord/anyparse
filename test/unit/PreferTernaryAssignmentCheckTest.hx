package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferTernaryAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-ternary-assignment` check: an `if (cond) lhs = a; else lhs = b;`
 * whose two branches assign the same l-value with the same operator is flagged
 * `Info` and `fix` collapses the pair to `lhs = cond ? a : b;`. Only a real
 * `if`/`else` (no else-if) of two single-statement binary assignments to a
 * textually identical l-value qualifies; the condition is parenthesised only
 * when it binds no tighter than `?:`.
 */
class PreferTernaryAssignmentCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x = 2;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-ternary-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/else assignment can be a single ternary assignment', vs[0].message);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x = 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x = a ? 1 : 2;', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tx = 1;\n\t\t} else {\n\t\t\tx = 2;\n\t\t}\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x = a ? 1 : 2;', es[0].text);
	}

	public function testFieldLvalueReproFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f() {\n\t\tif (value) _text.defaultTextFormat = _selectedTextFormat;\n\t\telse _text.defaultTextFormat = _blackTextFormat;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('_text.defaultTextFormat = value ? _selectedTextFormat : _blackTextFormat;', es[0].text);
	}

	public function testCompoundSameOperatorFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f() {\n\t\tif (a) x += 1;\n\t\telse x += 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x += a ? 1 : 2;', es[0].text);
	}

	public function testCompoundDifferentOperatorNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x += 1;\n\t\telse x -= 2;\n\t}\n}').length);
	}

	public function testPlainVsCompoundNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse x += 2;\n\t}\n}').length);
	}

	public function testDifferentLvalueNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse y = 2;\n\t}\n}').length);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t}\n}').length);
	}

	public function testElseIfChainNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tif (a) x = 1;\n\t\telse if (b) x = 2;\n\t\telse x = 3;\n\t}\n}').length
		);
	}

	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tx = 1;\n\t\t\ty = 2;\n\t\t} else x = 3;\n\t}\n}').length
		);
	}

	public function testNonAssignmentBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) g();\n\t\telse x = 2;\n\t}\n}').length);
	}

	public function testIncrementBranchesNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) x++;\n\t\telse x--;\n\t}\n}').length);
	}

	public function testTernaryConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (a ? b : c) x = 1;\n\t\telse x = 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('x = (a ? b : c) ? 1 : 2;', es[0].text);
	}

	public function testComparisonConditionNotWrapped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f() {\n\t\tif (x > 0) a = 1;\n\t\telse a = 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('a = x > 0 ? 1 : 2;', es[0].text);
	}

	public function testCommentInHeaderNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (a) /* keep */ x = 1;\n\t\telse x = 2;\n\t}\n}').length);
	}

	public function testNullNarrowingGuardNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f(s:Null<S>) {\n\t\tif (s != null && s.g()) x = 1;\n\t\telse x = 2;\n\t}\n}').length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-ternary-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-ternary-assignment'));
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTernaryAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTernaryAssignment = new PreferTernaryAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
