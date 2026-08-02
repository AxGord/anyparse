package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferTernaryExpression;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-ternary-expression` check: a 2-branch `if`-EXPRESSION in value position is
 * flagged `Info` and `fix` rewrites it to `cond ? then : else`. A CHAIN (its `else` another
 * `if`-expression, or the node itself an `else if` link), a bodied-construct branch, a control
 * -exit branch, and a comment in a dropped region are all left alone.
 */
class PreferTernaryExpressionCheckTest extends Test {

	public function testInitializerIfExpressionFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else 2;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-ternary-expression', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this two-branch if-expression can be a ternary', vs[0].message);
	}

	public function testFixInitializer(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
	}

	/** Value position is a property of the KIND, so `return` / argument positions need no extra handling. */
	public function testFixReturnPosition(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Int {\n\t\treturn if (c) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
	}

	public function testFixArgumentPosition(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tg(if (c) 1 else 2);\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('c ? 1 : 2', es[0].text);
	}

	/** The multi-line TM shape this check was written for (`ReadyMadeFileSystem.getFileName`, anonymized). */
	public function testFixMultiLineFixture(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(pathText:String):Int {\n\t\tfinal start:Int = if (lastSepIndex > 1 || !pathText.startsWith(\':\'))\n\t\t\tlastSepIndex\n\t\telse\n\t\t\t1;\n\t\treturn start;\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('lastSepIndex > 1 || !pathText.startsWith(\':\') ? lastSepIndex : 1', es[0].text);
	}

	/**
	 * A CHAIN is `prefer-if-expression-*`'s. BOTH halves of the chain gate are exercised here:
	 * the head is refused because its `else` is an `if`-expression, and the inner `else if` LINK
	 * — itself a perfectly legal 2-branch `if`-expression — because it is a link. Without the
	 * link half the fixed point unravelled the chain one level per pass into a nested ternary.
	 */
	public function testChainNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (a) 1 else if (b) 2 else 3;\n\t}\n}').length);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1;\n\t}\n}').length);
	}

	public function testStatementIfNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (c) g();\n\t\telse h();\n\t}\n}').length);
	}

	public function testBlockBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) { g(); h(); } else 2;\n\t}\n}').length);
	}

	public function testSwitchBranchNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else switch v {\n\t\t\tcase _: 2;\n\t\t};\n\t}\n}').length
		);
	}

	/** A real TM site before the exit gate existed: `a ? x : return` disguises control flow as a value. */
	public function testReturnBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfinal t:Float = if (c) 1 else return;\n\t}\n}').length);
	}

	public function testThrowBranchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) 1 else throw "e";\n\t}\n}').length);
	}

	/** The `if (` / `)` / `else` glue is dropped, so a comment sitting there fails the guard closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) /* why */ 1 else 2;\n\t}\n}').length);
	}

	/** A comment INSIDE a copied span rides along, so the site still fires. */
	public function testCommentInsideBranchFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar x = if (c) g(/* why */ 1) else 2;\n\t}\n}').length);
	}

	/** A ternary condition binds no tighter than `?:`, so it is the one shape that gets parentheses. */
	public function testTernaryConditionParenthesised(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tvar x = if (a ? b : c) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('(a ? b : c) ? 1 : 2', es[0].text);
	}

	public function testComparisonConditionBare(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tvar x = if (a > 1 && b) 1 else 2;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('a > 1 && b ? 1 : 2', es[0].text);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTernaryExpression().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTernaryExpression = new PreferTernaryExpression();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
