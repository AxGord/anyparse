package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.InvertNegatedIfElse;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `invert-negated-if-else` check: an `if` STATEMENT with an `else` whose condition's
 * top-level node is a logical not (`if (!c) A else B`) is flagged `Info`. The autofix drops
 * the `!` and swaps the branches (`if (c) B else A`), a semantics-safe exact complement. A
 * no-`else` `if`, an else-if chain, a non-top-level `!`, and a condition-comment case are
 * not flagged.
 */
class InvertNegatedIfElseCheckTest extends Test {

	public function testNegatedIfElseFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('invert-negated-if-else', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this negated if-else can be inverted — drop the ! and swap the branches', vs[0].message);
	}

	public function testBracedIfElseFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) { p(); } else { q(); }\n\t}\n}').length);
	}

	public function testParenWrappedConditionFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif ((!a)) x(); else y();\n\t}\n}').length);
	}

	public function testNonNegatedNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) x(); else y();\n\t}\n}').length);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x();\n\t}\n}').length);
	}

	public function testElseIfChainNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else if (b) y(); else z();\n\t}\n}').length);
	}

	public function testTopLevelAndNotFlagged(): Void {
		// The `!` negates only `a`; the condition's top-level node is `&&`, not a not.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a && b) x(); else y();\n\t}\n}').length);
	}

	public function testNotEqualNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a != b) x(); else y();\n\t}\n}').length);
	}

	public function testConditionCommentNotFlagged(): Void {
		// A comment inside the condition would be dropped by the rebuilt condition, so skip.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!/* c */a) x(); else y();\n\t}\n}').length);
	}

	public function testFixInvertsAndSwaps(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}');
		Assert.equals(3, es.length);
		Assert.equals('a', es[0].text);
		Assert.equals('y();', es[1].text);
		Assert.equals('x();', es[2].text);
	}

	public function testFixUnwrapsOperandParen(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tif (!(a && b)) x(); else y();\n\t}\n}');
		Assert.equals('a && b', es[0].text);
	}

	public function testFixAppliedOutput(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (a) y(); else x();\n\t}\n}', RefactorSupport.applyEdits(src, edits(src)));
	}

	public function testFixAppliedOutputBraced(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!a) { p(); } else { q(); }\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tif (a) { q(); } else { p(); }\n\t}\n}', RefactorSupport.applyEdits(src, edits(src))
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('invert-negated-if-else'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('invert-negated-if-else'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new InvertNegatedIfElse().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: InvertNegatedIfElse = new InvertNegatedIfElse();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
