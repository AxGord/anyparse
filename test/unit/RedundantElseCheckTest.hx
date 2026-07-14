package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.RedundantElse;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-else-after-return` check: an `else` whose `if` then-branch
 * always exits (`return` / `throw` / `break` / `continue`) is flagged `Info`,
 * only when the `if` is a direct block statement. `fix` de-nests the else body,
 * skipping a body that declares a local (scope would widen).
 */
class RedundantElseCheckTest extends Test {

	public function testElseAfterReturnFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse b();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-else-after-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this else is redundant — the if branch always exits', vs[0].message);
	}

	public function testElseAfterThrowFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\tif (a) throw "e";\n\t\telse b();\n\t}\n}').length);
	}

	public function testElseAfterBreakFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\twhile (c) {\n\t\t\tif (a) break;\n\t\t\telse b();\n\t\t}\n\t}\n}').length
		);
	}

	public function testThenBlockEndingInReturnFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\tx();\n\t\t\treturn 1;\n\t\t} else {\n\t\t\tb();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testThenFallsThroughNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) b();\n\t\telse c();\n\t}\n}').length);
	}

	public function testInlineNonBlockIfNotFlagged(): Void {
		// The inner `if` is the un-braced body of the outer `if`, not a block
		// statement — de-nesting its else would corrupt the outer's control flow.
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (outer)\n\t\t\tif (a) return 1; else b();\n\t}\n}').length);
	}

	public function testIfExpressionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tvar x = if (a) 1 else 2;\n\t\treturn x;\n\t}\n}').length);
	}

	public function testElseIfChainFlagsOuterOnly(): Void {
		// The inner `if` sits in the outer's else slot (not a block statement), so
		// only the outer else is flagged; the inner surfaces after a de-nest pass.
		Assert.equals(
			1,
			violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;\n\t}\n}').length
		);
	}

	public function testFixDeNestsSingleStatementElse(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse b();\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) return 1;\nb();', es[0].text);
	}

	public function testFixDeNestsBlockElse(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {\n\t\t\tb();\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('if (a) {\n\t\t\treturn 1;\n\t\t}\nb();', es[0].text);
	}

	public function testFixEmptyElseDropped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {}\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) {\n\t\t\treturn 1;\n\t\t}', es[0].text);
	}

	public function testFixScopeUnsafeSkipped(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {\n\t\t\tvar n = 1;\n\t\t\tb(n);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-else-after-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-else-after-return'));
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantElse().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: RedundantElse = new RedundantElse();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
