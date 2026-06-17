package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CollapsibleIf;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `collapsible-if` check: an `if` whose sole then-branch is another `if`, neither with
 * an `else`, is flagged `Warning`. The autofix merges the conditions with `&&`, wrapping a
 * lower-precedence operand (`a || c`) in parentheses. An `else` on either `if`, or a
 * then-branch with more than the nested `if`, is not flagged.
 */
class CollapsibleIfCheckTest extends Test {

	public function testNestedBlockIfFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (a) {\n\t\t\tif (b) p();\n\t\t}\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('collapsible-if', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('this if can be merged with its nested if using &&', vs[0].message);
	}

	public function testBareNestedIfFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif (a) if (b) p();\n\t}\n}').length);
	}

	public function testOuterElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) {\n\t\t\tif (b) p();\n\t\t} else q();\n\t}\n}').length);
	}

	public function testInnerElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) {\n\t\t\tif (b) p(); else r();\n\t\t}\n\t}\n}').length);
	}

	public function testMultiStatementBlockNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) {\n\t\t\tp();\n\t\t\tif (b) q();\n\t\t}\n\t}\n}').length);
	}

	public function testFixMergesWithAnd(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a) if (b) p();\n\t}\n}';
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		Assert.equals(2, edits.length);
		Assert.equals('a && b', edits[0].text);
		Assert.equals('p();', edits[1].text);
	}

	public function testFixWrapsLowerPrecedenceOperand(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a || c) if (b) p();\n\t}\n}';
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		Assert.equals('(a || c) && b', edits[0].text);
	}

	public function testFixWrapsAssignmentOperand(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a = next()) if (b) p();\n\t}\n}';
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		Assert.equals('(a = next()) && b', edits[0].text);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('collapsible-if'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('collapsible-if'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new CollapsibleIf().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final check: CollapsibleIf = new CollapsibleIf();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
