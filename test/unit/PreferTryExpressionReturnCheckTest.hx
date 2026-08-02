package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferTryExpressionReturn;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-try-expression-return` check: a statement-position `try` whose body and EVERY
 * catch clause is a single valued `return` is flagged `Info` and `fix` collapses it to
 * `return try <value> catch (…) <value>;`. A value-less `return;`, a non-`return` / empty /
 * rethrowing catch, a multi-statement body and a comment in a dropped region are all left
 * alone.
 */
class PreferTryExpressionReturnCheckTest extends Test {

	private static final BASIC: String =
		'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}';

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(BASIC);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-try-expression-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this try/catch returning in every path can be a single try-expression return', vs[0].message);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> = edits(BASIC);
		Assert.equals(1, es.length);
		Assert.equals('return try parse(text) catch (e:String) 0;', es[0].text);
	}

	/** The catch header is sliced VERBATIM, so the variable's `:Type` (trivia in the projection) survives every clause. */
	public function testFixTwoCatches(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t} catch (e:Exception) {\n\t\t\treturn -1;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return try parse(text) catch (e:String) 0 catch (e:Exception) -1;', es[0].text);
	}

	/** An un-braced body is the same shape with the block level absent. */
	public function testUnbracedBodiesFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\ttry return a; catch (e:String) return 0;\n\t}\n}').length);
	}

	/** The rewrite touches only the `try` node, so no statement-list walk gates it inside a `#if`. */
	public function testInsideConditionalFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\t#if sys\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t}\n\t\t#end\n\t}\n}'
			).length
		);
	}

	public function testVoidReturnInCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testNonReturnCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\tlog(e);\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testEmptyCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {}\n\t}\n}').length
		);
	}

	public function testSecondCatchWithoutReturnNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t} catch (e:Exception) {\n\t\t\tthrow e;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/**
	 * A deliberately grouped body is never collapsed. The `return` comes FIRST (the trailing statement is unreachable, which is the only way to reach this gate at all -- anything BEFORE a valued return is rejected one gate earlier, by the return check itself).
	 */
	public function testMultiStatementBodyNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t\tlog(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** The `try` keyword, the braces and each `return` are dropped, so a comment there fails the guard closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\t// fast path\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A comment INSIDE a copied returned expression rides along, so the site still fires. */
	public function testCommentInsideValueFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(/* raw */ text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** The TM shape this check was written for (`ScrollAxis.maxScroll`, anonymized). */
	public function testFixTmFixture(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(node:Node, size:Float):Float {\n\t\ttry {\n\t\t\treturn Math.max(0, measure(node) - size);\n\t\t} catch (exception:Exception) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return try Math.max(0, measure(node) - size) catch (exception:Exception) 0;', es[0].text);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTryExpressionReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTryExpressionReturn = new PreferTryExpressionReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
